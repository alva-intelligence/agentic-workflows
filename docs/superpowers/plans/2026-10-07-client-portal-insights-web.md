# Client Portal — Insights (the brand share dashboard inside the portal) — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in client opens **Insights** from the portal at `/s/{workspace}/{brand}/insights/…` and sees the same read-only dashboard the public link shows at `/share/brand/{slug}`, limited to the tabs the agency ticked **Clients** for. The agency gets that column in Brand Settings → Insights Tabs and a "Preview as client" view. The Overview's Review Signal / Ask a follow-up / refresh controls stop leaking onto every read-only surface.

**Architecture:** The share pages are separated into access and presentation.

- An **`InsightSurface`** says where a read-only surface reads its data and where its links point:
  - `api`: `{ client, prefix, baseURL?, headers? }`;
  - `basePath`, `cacheKey`, `audience`: `"public" | "client" | "preview"`.

  It rides on the existing `PublicShareContext`. `PublicShareProvider` keeps its props and builds the share surface from `slug` + `accessToken` when none is passed, so `/share/dashboard` and every `useIsPublicView()` reader keep working.
- **Readers:**
  - The 27 share insight readers (`src/services/query.ts`, `labelling/api.ts`, `creative-analysis/api.ts`) take `InsightApi` instead of `(slug, accessToken)`.
  - `shareInsightSurface(slug, token).api` reproduces today's calls byte for byte.
  - The portal surface sends the same paths through the BFF (`/s/api/portal/{ws}/{brand}/insight/…`).
- **Pages:**
  - The share page bodies move to `src/components/insight-surface/pages/*` and take their ids as props.
  - `/share/brand/[slug]/**` route files become thin wrappers.
  - The portal and the preview render the same bodies from one optional catch-all, `[[...tab]]`, via a pure `resolveInsightRoute`.
- **Layout:**
  - `InsightSurfaceLayout` owns the tab list, the redirect away from hidden or unknown paths, the header row and the "Sample data" pill.
  - It takes `pathname`, `onNavigate` and `onReplace` as props, so it renders without an app router in tests.
  - The share layout passes `ShareInsightFrame` (its floating chrome). The portal and the preview use the inline frame.
- **Portal route:**
  - A server `insights/layout.tsx` checks the session and the client-visible tab list. It hands both to a client wrapper that keeps the portal header mounted across tab switches.
  - A 401 sends the page back to sign-in. A 404 re-checks `insight-info`: the tab may have been hidden, or the lane revoked.

**Tech Stack:** Next.js 16 app router (async `params`, optional catch-all, server layouts, `middleware.ts`), React 19, TypeScript, Tailwind 3.4, TanStack Query v5, axios, `@base-ui/react` (frndOS v2), Radix/Headless (frndOS v1), PostHog (`posthog-js`), `bun test` (vitest-compatible API, jsdom preload), Testing Library.

**Spec:** `docs/superpowers/specs/2026-10-07-client-portal-insights-design.md` (workspace root). This plan is the web half: §4 (4.1–4.6) and the web side of I-1…I-6. The context spec is `docs/superpowers/specs/2026-10-06-client-portal-from-share-links-design.md` (portal, `client.session`, BFF, lanes). The api half is `docs/superpowers/plans/2026-10-07-client-portal-insights-api.md`, written in parallel.

## API contract assumed

> **Reconciled with the api plan (2026-10-07, coordinator) — `2026-10-07-client-portal-insights-api.md` § "API contract for web" is authoritative:**
> 1. `insight-info` uses the public share envelope (`data.brand_name`, `data.brand_logo`, `data.insights_tab_settings.resolved`, `owned_media_table_view`); every tab key is present with `is_visible` = client-visible. Keep the normaliser, but code against these keys.
> 2. **Preview as client endpoints exist** (api Task 6b): `v1/brands/{brand}/client-preview/insight-info` and `v1/brands/{brand}/client-preview/insight/*`, same sub-paths and shapes as the portal, authenticated with the normal `axiosInstance` (`permissions:brand.settings.read`). Task 12 is unblocked.
> 3. Settings rows carry `client_visible`; a PUT without it keeps the stored value; a row with only `client_visible: true` survives.
> 4. The 27 insight sub-paths are the api plan's list (Task 5) — the BFF allowlist must match it exactly.
> 5. "Sample data" on Listening: show the pill wherever fixtures render (the demo brands); non-demo brands keep the existing "connect" empty state with no pill. Business: always.


The api plan is written in parallel. The web codes against the shapes below. Anything spec §3 pins is copied from it. Anything marked **(assumed)** is the web's reading; it must be reconciled with the api plan's contract section before Task 9 (portal) and Task 12 (preview) merge. Task 14 Step 6 does the reconciliation.

**Portal (session `X-Client-Session`, middleware `client.session:brand`, `throttle:public-portal`, `Cache-Control: no-store`)**

| Call | Answer |
|---|---|
| `GET public/portal/{ws}/{brand}/insight-info` | `200 { data: { brand_id, brand_name, brand_logo, owned_media_table_view, insights_tab_settings: { resolved: { <tab_key>: { label, is_visible } } } } }`. `is_visible` here = the tab's `client_visible` (spec §3.1 `resolveForClients`). **(assumed)** It uses the `getBrandResponse` keys (`brand_name`, `brand_logo`, `insights_tab_settings.resolved`) the spec says it "matches". Spec §3.3 also lists `name`, `logo`, `tabs`, so the web's normaliser (Task 8) accepts either spelling, and `tabs` as a map or as an array of `{ id \| key, label, is_visible }`. A hidden tab may be omitted or sent with `is_visible: false`; the web treats both as hidden. |
| `GET public/portal/{ws}/{brand}/insight/<path>` for every share insight path (list below), and `POST …/insight/reports/query` | The same body and query vocabulary as `v1/share/brand/{slug}/insight/<path>`, trimmed for `client` (spec §3.4): signals carry no `ideations`, reports carry no `createdBy`, and reports from another brand are excluded. |
| any portal call without a valid session | `401 { code: "session_required" }` |
| a tab not client-visible, or a revoked lane | `404 { message: "Not found." }` |
| any session-authenticated 2xx | `X-Client-Session-Expires-At` (already handled by `portalProxy`). |

The 27 mirrored insight paths (the BFF allowlist in Task 6 is exactly this list):
- 23 GET:
  - `overview`, `home`, `signals`, `signals/{id}`, `reports`, `reports/{id}`, `report-templates`, `campaign`, `campaign/filters`;
  - `paid-media/overview`, `paid-media/detail`, `paid-media/filters`;
  - `owned-media/overview`, `owned-media/detail`, `owned-media/sentiment`, `owned-media/filters`;
  - `earned-media`, `earned-media/influencers`, `earned-media/filters`;
  - `atl/overview`, `atl/detail`, `atl/filters`.
- 3 owned-media reads from `labelling` / `creative-analysis`:
  - `owned-media/label-attributes`;
  - `owned-media/creative/playbooks`, `owned-media/creative/playbook`;
  - `owned-media/content/{id}/creative-analysis`.

  (The 22 static GETs above plus these give 26 GET shapes, `signals/{id}` and `reports/{id}` included.)
- 1 POST: `reports/query`.

**Agency settings (`axiosInstance`, permission as today's Insights Tabs settings)**

| Call | Answer |
|---|---|
| `GET v1/brands/{brand}/insights-tab-settings` | `{ data: { overrides: { <tab>: { label, is_visible, client_visible } } } }`. **(assumed)** `client_visible` is a per-row boolean, and an absent row or key reads as `false`. |
| `PUT v1/brands/{brand}/insights-tab-settings` `{ overrides: { <tab>: { label, is_visible, client_visible } } }` | As today. **(assumed)** (a) A row with `label: null, is_visible: null, client_visible: true` is KEPT, not deleted. Today an all-null row is deleted, and `client_visible: true` must keep it. (b) A PUT row without `client_visible` leaves the stored value untouched. The workspace endpoint never receives the key. |

**Preview as client (agency session) — NOT in spec §3; must be added by the api plan (assumed)**

Spec §4.3 has the preview render "through the agency's own session". The portal endpoints need a client session, and the share endpoints need the public link on, plus its token. So the web assumes a third route group under the same resolver design (I-1). Its access is the signed-in agency user, with `brand.settings` read. Its audience is `client`: the same tab filter and the same trims.

| Call | Answer |
|---|---|
| `GET v1/brands/{brand}/client-preview/insight-info` | the portal `insight-info` shape |
| `GET v1/brands/{brand}/client-preview/insight/<path>` and `POST …/insight/reports/query` | the portal insight payloads |

If the api plan declines this group, Task 12 stops at Step 1 and records "preview blocked on api" in the track. Tasks 0–11 and 13–14 do not depend on it.

## Global Constraints

- **Where to work:**
  - Worktree **WT** = `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-portal`, branch `feature/daffa/vc-client-portal` (continue; no new branch).
  - Agent shells reset cwd, so every command starts with `cd` to that literal path; `cd WT` below means exactly that path.
  - Never write in `web/` itself: Daffa may be live-testing there (memory: no write agents during live testing). Never touch `api/`.
- **Git:**
  - Use `/usr/bin/git` and `/usr/bin/grep`, because an rtk hook rewrites plain `git`/`grep` output.
  - The shell is zsh. Put file lists in arrays (`F=(a b)`) and quote every path containing `(`, `[` or `]`.
  - Commit with `/usr/bin/git commit -F - <<'EOF' … EOF`. The subject is `<type>(web): …`, and the last line is `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - **Never push. Never `git stash`** (memory: a popped stale stash corrupted files). Never open a PR.
- **Tools through `./node_modules/.bin/`:** a shell hook rewrites bare `eslint`/`prettier`/`tsc`. So:
  - `./node_modules/.bin/tsc --noEmit -p .`;
  - `./node_modules/.bin/eslint <files>`;
  - `./node_modules/.bin/prettier --write <files>`.

  Build with `node ./node_modules/next/dist/bin/next build`, never `bun run build` (memory: broken). The build does NOT type-check (`ignoreBuildErrors`).
- **Tests:**
  - Run `bun test <file>`, ONE file per invocation. Never pass a directory (memory: a directory run blew up to 26 GB), and never use `bunx vitest`.
  - Query with `const body = () => within(document.body)`, never `screen` (memory: RTL `screen` is broken under bun).
  - Import `"@testing-library/jest-dom/vitest"` at the top of component tests, and call `cleanup()` in `afterEach`.
  - Keep every test file **< 45 KB**: run `wc -c` before adding to an existing one, because bun dies past ~51 KB with a bogus SCSS error (memory).
  - Read bun's `N error` line: a file that dies at import shows as one error, not as failures.
  - bun has no `vi.hoisted`, `vi.mocked` or `vi.waitFor`. Use RTL `waitFor` and cast spies.
  - **No test lives under `src/app/**/[…]/`**. Route files are thin wrappers, and tests target the components and libs they call.
- **Mocks:** **never `vi.mock` / `mock.module`** (memory: bun's module registry is process-global and binds once; seven incidents). Spy on the edges:
  - `vi.spyOn(axiosPublic, "get" | "post")`, `vi.spyOn(axiosInstance, "get")` (`import axiosInstance, { axiosPublic } from "@/services/axios"`);
  - `vi.spyOn(posthog, "capture")` (`import posthog from "posthog-js"`);
  - `vi.spyOn(globalThis, "fetch")`.

  Call `vi.restoreAllMocks()` in `beforeEach`. Only route files (`src/app/**`) may import `@/lib/featureFlags`; components read toasts only as `useToastStore((s) => s.showToast)`.
- **`next/navigation` stays in route files and two named wrappers:** `src/app/**`, `src/components/client-lane/portal/PortalInsightsRoute.tsx` and `src/components/insight-surface/InsightSurfaceRoutePage.tsx`. jsdom has no app router, and `useRouter()` throws there. New components take `pathname`, `onNavigate(href)` and `onReplace(href)` as props, and tests pass `vi.fn()`. The twelve page bodies MOVED in Task 4 keep the `useRouter` calls they already had; no unit test renders them.
- **Every new test proves itself (memory: plan tests written from reasoning were vacuous 6×):**
  - Watch it FAIL for the stated reason before implementing.
  - Recompute every expected value from the real code, not from this plan.
  - After it passes, apply the **named mutation**, watch the named test fail, restore, and watch it pass.
  - If an expectation disagrees with code that matches the spec, fix the expectation and log it in the track. `toEqual` ignores `undefined` properties, so a "key is absent" claim asserts `Object.keys(…)`, never `toEqual`.
- **Type gate:**
  - `./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"` must stay ≤ the Task 0 baseline (877 when the portal plan closed).
  - `… | /usr/bin/grep -F -f /tmp/portal-insights-touched.txt` must show no NEW lines.
- **Lint / format:**
  - `./node_modules/.bin/eslint <touched files>` must report 0 errors and no new warnings on changed lines.
  - Run `prettier --write` on NEW files, and on modified files whose base version is prettier-clean.
  - **Not prettier-clean on the base, so hand-format them and never run prettier on them:**
    - `src/components/brands/CampaignContent.tsx`;
    - `src/hooks/useCustomReports.ts`;
    - `src/app/(dashboard)/brands/[id]/settings/insights-tabs/page.tsx`;
    - `src/lib/insightsTabResolution.ts`.

    Task 0 re-checks this list.
- **frndOS components first:**
  - Before any UI task, read `WT/.claude/skills/frndos-ui/SKILL.md`, then `frndos-components-v2`, `frndos-components`, `frndos-design-foundations` (Appearance tri-mode, `bg-app`) and `frndos-rules`.
  - Priority: v2 → v1. **No new frndOS component and no change to any v2 component's API.**
  - **One file never imports both v1 (`@/components/frndos`, `@/components/frndos/<Name>`) and v2 (`@/components/frndos/v2`).** v2 pieces enter v1 files only through single-purpose wrapper files:
    - `SampleDataPill.tsx` (v2 `ItemRow.Tag`);
    - `ClientVisibleCheckbox.tsx` (v2 `Checkbox`).

    `InsightSurfaceLayout.tsx` imports v1 `TabsRounded` directly from `@/components/frndos/TabsRounded`, not from the barrel, which drags in the floating chrome. `InsightsTabSettingsForm.tsx` stays v1-only.
- **Tokens only** on every line this plan writes or rewrites:
  - text `text-text-inverse`, `-subtle`, `-subtlest`;
  - sizes `text-textXs`, `text-textXsMedium`, `text-textSm`, `text-textSmMedium`;
  - radius `rounded-full`, `-2xl`, `-xl`;
  - grounds `bg-app`, films `bg-white/5`, `/10`;
  - borders `border-border-default`, `border-white/10`;
  - `font-geist`.

  Never use `text-white`, `text-[Npx]`, an arbitrary `white/[0.0x]` or a new hex (memory: dark hex is invisible to the Aurora sweep). `/s` pages follow the viewer's appearance: a `bg-app` ground, no page-level `data-theme-scope="dark"`, no `data-client-lane-page` (`tokenHygiene.publicPages.test.ts`).
- **Copy:**
  - From the spec: Insights; Clients; Preview as client; Sample data.
  - Chosen by this plan: "Show {tab} to clients"; "Tick Clients to open a tab in your clients' portal."; "Save your changes to preview them."; "Previewing what clients see"; "Only the tabs ticked under Clients appear, read-only."; "Back to settings"; "No tabs are open to clients yet."; "Tick Clients on a tab, then save."; "Couldn't load the preview."; page title "Insights — frndOS".
- **/share stays the same:**
  - every share reader sends the same URL, query and `X-Share-Token` header;
  - every share query key keeps the bare slug (`cacheKey === slug`);
  - tab labels, order, visibility and redirects are unchanged.

  Two deliberate differences: the Overview hides its three agency controls (Task 1, spec I-6), and the share ground becomes `bg-app` (Task 13; identical in Midnight, follows Aurora).
- **Security:**
  - The client session token never reaches page JS. The portal surface carries no `X-Share-Token`.
  - The BFF proxies only the 27 insight shapes plus `insight-info` (GET only, except `reports/query`), and `safeSegments` still guards every segment.
  - Run the `security-review` skill before handover (Task 14).
- **Analytics:** only through typed helpers, never an inline `posthog.capture`.
  - `client_lane.portal_insights_viewed {tab}` is public and PII-free.
  - `insights_tab_client_visibility_changed {tab, visible}` and `insights_preview_as_client_opened` are agency events; base context is automatic, so never pass `brand_id`.
  - Every new event is listed for the Lark taxonomy in Task 14.
- **Flag:**
  - The Clients column and Preview as client sit behind `show-client-lane` (`useClientLaneEnabled()`), read in route files only.
  - `/s/*` stays unflagged.
- **Next 16 (read `WT/node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/dynamic-routes.md` §"Optional Catch-all Segments" and `layout.md` §"Layouts do not rerender" before Tasks 9 and 12):**
  - `params` is a `Promise` in layouts and pages.
  - `[[...tab]]` also matches the bare `/insights` (`tab` is `undefined`).
  - A layout does not re-render on navigation, so the shell reads `usePathname()` in a client wrapper.
  - `middleware.ts` is deprecated in favour of `proxy.ts` but stays this repo's file; do not migrate it.

## Review Focus

These are the inputs the spec implies but no happy path exercises, most likely to bite first. Each one has a named test in its owning task.

1. **A client lands on a tab the agency did not open**: a deep link, a stale bookmark, or an `insight-info` with no map at all. The client must see only ticked tabs and be moved to the first one. A missing map must mean NO tabs, never all of them: `resolvedMapToTabs` reads a missing key as visible. → Task 5 ("treats a missing map as no tabs for clients", "redirects a hidden tab to the first open one").
2. **Access removed or a tab unticked while Insights is open.** The next insight call answers 404 (or 401). The page must re-check and fall back to sign-in, or to the remaining tabs. A single missing report must not reload in a loop. → Task 9 ("rechecks access on a 404 and hands back to sign-in when the brand is gone", "goes back to Approvals when no tab is open any more", "does not reload for a 404 when the brand is still open").
3. **A path outside the mirrored insight shapes through the BFF**: a DELETE, another POST, an unknown sub-path, or a `..` segment that still matches a shape (`signals/..`). It must 404 without calling the api. → Task 6 ("404s an insight path outside the mirror without calling the api").
4. **The public share link after the refactor.** It must send the identical URL, header and query for all 27 readers, and the open-link case must send no token header. → Task 3 (the reader table and "sends no token header on an open link"), Task 1 (only the three Overview controls disappear).
5. **A brand with zero client-visible tabs.** There must be no Insights item in the nav, and `/insights` must go straight back to Approvals: no empty strip, no flash of the first default tab. → Task 8 ("hides Insights when no tab is open to clients"), Task 9 (the server redirect, and "goes back to Approvals when no tab is open any more").

Also pinned, as cheaper rules:
- A settings PUT never carries `client_visible` for the `dashboard` row or for workspace scope (Task 11).
- Preview is disabled while the form has unsaved changes (Task 12).

---

## File Structure

All paths are relative to WT.

| File | Status | Responsibility |
|---|---|---|
| `docs/tracks/client-portal.track.md` | modify | New "Insights (plan 2026-10-07)" section: baselines, checklist, session log |
| `src/components/brands/insight/DailySummaryOverview.tsx` (+ `.test.tsx`) | modify/create | Hide refresh, Review Signal and Ask a follow-up on read-only surfaces (I-6) |
| `src/lib/insight-surface/types.ts` | create | `InsightAudience` |
| `src/services/insightSurface.ts` (+ `.test.ts`) | create | `InsightApi`, `InsightSurface`, `shareInsightSurface` / `portalInsightSurface` / `previewInsightSurface`, `insightRequest` / `insightGet` / `insightPost`, `insightHref`; `fetchClientPreviewInfo` (Task 12) |
| `src/context/PublicShareContext.tsx` (+ `.test.tsx`) | modify/create | Context carries `surface`; `useInsightSurface()`; provider prop `surface?` |
| `src/services/query.ts` | modify | 23 share readers take `InsightApi` |
| `src/services/labelling/api.ts`, `src/services/creative-analysis/api.ts` | modify | Share contexts become `InsightApi` |
| `src/services/insightReaders.test.ts` | create | The 27-reader wire table (share unchanged; portal through the BFF) |
| `src/services/labelling/hooks.ts`, `src/services/creative-analysis/hooks.ts`, `src/hooks/useCustomReports.ts`, `src/hooks/useReportTemplates.ts` | modify | Read the surface |
| `src/components/brands/CampaignContent.tsx`, `src/components/brands/insight/PaidMediaContent.tsx`, `src/components/brands/insight/SentimentAnalysis.tsx`, `src/components/signal-trends/SignalTrendsListContent.tsx`, `src/components/signal-detail/SignalDetailContent.tsx` | modify | Read the surface; hrefs from `basePath` |
| `src/components/brands/TrendsSignalSection.tsx`, `src/components/brands/OverviewHomeContent.tsx` | modify | `shareSlug` → `shareBasePath` |
| `src/components/insight-surface/pages/Insight*Page.tsx` (12 files) | create (moved) | The share page bodies; detail pages take ids as props |
| `src/app/share/brand/[slug]/**/page.tsx` (12 files) | modify | Thin wrappers over the moved bodies |
| `src/app/share/brand/[slug]/campaigns/page_old_jeff.tsx` | modify | Its one reader call (dead file, kept compiling) |
| `src/lib/insight-surface/routes.ts` (+ `.test.ts`) | create | `resolveInsightRoute(segments)` |
| `src/components/insight-surface/InsightTabRouter.tsx` | create | Route → page body |
| `src/lib/insight-surface/tabs.ts` (+ `.test.ts`) | create | Tab inventory, strict client filter, matching, redirect, `isClientEligibleTab` |
| `src/components/insight-surface/InsightSurfaceLayout.tsx` (+ `.test.tsx`) | create | Tabs, redirect, header row, pill; `InlineInsightFrame` |
| `src/components/insight-surface/ShareInsightFrame.tsx` | create | The share route's floating chrome (moved from the layout) |
| `src/app/share/brand/[slug]/layout.tsx` | modify | Data + password wall only; renders `InsightSurfaceLayout` |
| `src/lib/client-lane/portal/proxy.ts` | modify | `insight_info` / `insight` routes, `insightRouteAllowed` |
| `src/lib/client-lane/portal/proxy.insights.test.ts` | create | Allowlist + forwarding tests |
| `src/middleware.ts`, `src/middleware.portal.test.ts` | modify | Portal page regex admits `/insights/**` |
| `src/lib/analytics/client-lane-events.ts`, `src/lib/analytics/brand-settings-events.ts` | modify | The three events |
| `src/lib/analytics/insights-client.events.test.ts` | create | Event names and props |
| `src/lib/client-lane/portal/insightInfo.ts` (+ `.test.ts`) | create | `PortalInsightInfo`, `normaliseInsightInfo`, `hasClientInsights`, `insightErrorAction` |
| `src/lib/client-lane/portal/insightInfoServer.ts` (+ `.test.ts`) | create | Server fetch of `insight-info` with the session |
| `src/lib/client-lane/portal/server.ts` | modify | `resolvePortalInsightInfoServer` |
| `src/lib/client-lane/portal/shell.ts`, `shell.test.ts` | modify | `portalInsightsHref` |
| `src/components/client-lane/portal/PortalNav.tsx` | modify | Insights item only with an `insightsHref`; navigates |
| `src/components/client-lane/portal/PortalApp.tsx`, `PortalApp.test.tsx` | modify | `insightsHref` prop |
| `src/app/s/[token]/[brand]/page.tsx` | modify | Computes `insightsHref` |
| `src/services/client-portal.ts` | modify | `fetchPortalInsightInfo`, `usePortalInsightInfo`, `isPortalInsightInfoKey` |
| `src/services/client-portal.insights.test.ts` | create | Browser info call through the BFF |
| `src/components/client-lane/portal/PortalFrame.tsx` | modify | `wide` prop |
| `src/components/client-lane/portal/PortalInsightsApp.tsx` (+ `.test.tsx`) | create | Portal Insights shell: header + nav + surface + recheck + view event |
| `src/components/client-lane/portal/PortalInsightsRoute.tsx` | create | Client wrapper: `usePathname` / `useRouter` → props |
| `src/components/insight-surface/InsightSurfaceRoutePage.tsx` | create | Shared `[[...tab]]` page body (portal + preview) |
| `src/app/s/[token]/[brand]/insights/layout.tsx`, `src/app/s/[token]/[brand]/insights/[[...tab]]/page.tsx` | create | The portal Insights route |
| `src/components/brands/reports/ReportView.tsx` | modify | Creator row only when `createdBy` is present (I-5 trim) |
| `src/lib/insight-surface/sampleData.ts` (+ `.test.ts`) | create | `showsSampleData` |
| `src/components/insight-surface/SampleDataPill.tsx` | create | v2 `ItemRow.Tag` wrapper |
| `src/services/insightsTabSettings.ts` | modify | `client_visible` on the wire type |
| `src/lib/insightsTabResolution.ts` | modify | `TabOverride.client_visible?` |
| `src/lib/insight-surface/clientVisibility.ts` (+ `.test.ts`) | create | `clientVisibilityChanges` |
| `src/components/brands/settings/insightsTabs/ClientVisibleCheckbox.tsx` | create | v2 `Checkbox` wrapper |
| `src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.tsx` (+ `.clients.test.tsx`) | modify/create | Clients column; Preview as client |
| `src/components/brands/settings/sections/InsightsTabSettingsSection.tsx` | modify | Pass-through + visibility event on save |
| `src/app/(dashboard)/brands/[id]/settings/insights-tabs/page.tsx` | modify | Flag + preview navigation |
| `src/components/insight-surface/InsightClientPreview.tsx` (+ `.test.tsx`) | create | Preview shell |
| `src/app/(dashboard)/brands/[id]/settings/insights-tabs/preview/layout.tsx`, `…/preview/[[...tab]]/page.tsx` | create | The preview route |
| `src/lib/client-lane/tokenHygiene.test.ts`, `src/lib/client-lane/tokenHygiene.publicPages.test.ts` | modify | New surfaces in the banned-class scans |

---

### Task 0: Pre-flight — sync, baselines, track section

**Files:**
- Modify: `docs/tracks/client-portal.track.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `TSC_BASELINE`, the baseline test results, and the prettier-clean list, all recorded in the track's new "Insights" section. Every later gate compares against these.

- [ ] **Step 1: Confirm the worktree is clean and on the branch**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-portal && /usr/bin/git rev-parse --abbrev-ref HEAD && /usr/bin/git status --short && /usr/bin/git log --oneline -1
```

Expected: `feature/daffa/vc-client-portal`, no status lines, and the tip commit.
- If `git status` lists anything, STOP and ask Daffa (AskUserQuestion): "The client-portal worktree has uncommitted changes: <list>. Commit them first, or should I wait?" Never stash.

- [ ] **Step 2: Pull if the branch has an upstream**

```bash
cd WT && (/usr/bin/git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null && /usr/bin/git pull --ff-only) || echo NO_UPSTREAM
```

Expected: either `Already up to date.` / a fast-forward, or `NO_UPSTREAM` (the branch is local-only; record that in the track). If the pull refuses (diverged), STOP and ask Daffa; never merge or rebase on your own.

- [ ] **Step 3: Install (in case the lockfile moved) and read the docs this plan leans on**

```bash
cd WT && bun install && ls .env.local && sed -n 95,130p node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/dynamic-routes.md && /usr/bin/grep -n "do not rerender\|do not re-render" node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/layout.md
```

Expected:
- the install finishes;
- `.env.local` exists (memory: a worktree without it never calls the api);
- the optional catch-all table shows `{ slug: undefined }` for the bare path;
- the layout doc's "do not rerender" lines print.

- [ ] **Step 4: tsc baseline**

```bash
cd WT && ./node_modules/.bin/tsc --noEmit -p . > /tmp/portal-insights-tsc-base.txt 2>&1; /usr/bin/grep -c "error TS" /tmp/portal-insights-tsc-base.txt; /usr/bin/grep -oE "^src/[^(]+" /tmp/portal-insights-tsc-base.txt | /usr/bin/grep -E "services/query|labelling|creative-analysis|PublicShareContext|share/brand|signal-trends|signal-detail|CampaignContent|PaidMediaContent|SentimentAnalysis|useCustomReports|useReportTemplates|TrendsSignalSection|OverviewHomeContent|DailySummaryOverview|ReportView|client-lane/portal|middleware|insightsTab|InsightsTab|insights-tabs|brand-settings-events|client-lane-events" | sort | uniq -c
```

Expected: one whole-project number (877 when the portal plan closed), plus per-file counts for files this plan touches (often none). Both go into the track (Step 7).

- [ ] **Step 5: Prettier-clean check of every file this plan modifies**

```bash
cd WT && F=(src/services/query.ts src/services/labelling/api.ts src/services/labelling/hooks.ts src/services/creative-analysis/api.ts src/services/creative-analysis/hooks.ts src/hooks/useCustomReports.ts src/hooks/useReportTemplates.ts src/context/PublicShareContext.tsx src/components/brands/CampaignContent.tsx src/components/brands/insight/PaidMediaContent.tsx src/components/brands/insight/SentimentAnalysis.tsx src/components/signal-trends/SignalTrendsListContent.tsx src/components/signal-detail/SignalDetailContent.tsx src/components/brands/TrendsSignalSection.tsx src/components/brands/OverviewHomeContent.tsx src/components/brands/insight/DailySummaryOverview.tsx src/components/brands/reports/ReportView.tsx "src/app/share/brand/[slug]/layout.tsx" src/lib/client-lane/portal/proxy.ts src/lib/client-lane/portal/server.ts src/lib/client-lane/portal/shell.ts src/middleware.ts src/components/client-lane/portal/PortalNav.tsx src/components/client-lane/portal/PortalApp.tsx src/components/client-lane/portal/PortalFrame.tsx "src/app/s/[token]/[brand]/page.tsx" src/services/client-portal.ts src/lib/analytics/client-lane-events.ts src/lib/analytics/brand-settings-events.ts src/services/insightsTabSettings.ts src/lib/insightsTabResolution.ts src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.tsx src/components/brands/settings/sections/InsightsTabSettingsSection.tsx "src/app/(dashboard)/brands/[id]/settings/insights-tabs/page.tsx"); ./node_modules/.bin/prettier --check "${F[@]}" 2>&1 | /usr/bin/grep warn
```

Expected: exactly these four `[warn]` lines, plus the summary line:
- `CampaignContent.tsx`;
- `useCustomReports.ts`;
- `insights-tabs/page.tsx`;
- `insightsTabResolution.ts`.

Any other file that warns joins the hand-format list. Record the final list in the track.

- [ ] **Step 6: Baseline suites, one file per invocation**

```bash
cd WT && F=("src/app/share/dashboard/[slug]/page.test.tsx" src/components/brands/reports/ReportsContent.test.tsx src/services/creative-analysis/hooks.test.ts src/hooks/useSocialListening.test.ts src/hooks/useBrandReports.test.ts src/constants/insightsTabs.test.ts src/components/frndos/DashboardFloatingChrome.test.tsx src/components/brands/insight/OwnedMediaFunnelSection.test.tsx src/lib/client-lane/portal/proxy.test.ts src/lib/client-lane/portal/me.test.ts src/lib/client-lane/portal/shell.test.ts src/services/client-portal.test.ts src/middleware.portal.test.ts src/middleware.mobile.test.ts src/middleware.kvShare.test.ts src/components/client-lane/portal/PortalApp.test.tsx src/components/client-lane/portal/PortalHeader.test.tsx src/components/client-lane/portal/PortalSignIn.test.tsx src/components/client-lane/portal/LaneExchange.test.tsx src/lib/client-lane/tokenHygiene.test.ts src/lib/client-lane/tokenHygiene.publicPages.test.ts src/lib/analytics/client-lane-events.portal.test.ts src/lib/theme.test.ts src/components/frndos/v2/Checkbox.test.tsx src/components/frndos/v2/ItemRow.test.tsx); for f in "${F[@]}"; do echo "== $f"; [ -f "$f" ] || { echo MISSING; continue; }; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: pass/fail counts per file.
- A file printed as `MISSING` does not exist; drop it from the later gate lists and record that.
- Record EVERY `(fail)` line name verbatim in the track. Later tasks compare their run of the same file against this list, and a failure not on the list is a regression.

- [ ] **Step 7: Add the Insights section to the track**

In `docs/tracks/client-portal.track.md`:
- Insert this block **above** `## Session Log`.
- Append the session entry at the end of the file.
- Leave every existing line as it is.

```markdown
## Insights (plan 2026-10-07)

Plan: `docs/superpowers/plans/2026-10-07-client-portal-insights-web.md` (workspace root). Spec: `docs/superpowers/specs/2026-10-07-client-portal-insights-design.md`. The api half: `docs/superpowers/plans/2026-10-07-client-portal-insights-api.md`, same branch name in `api/`.

### Baselines (Insights Task 0)

- insights-base: <short sha printed in Step 1> (`feature/daffa/vc-client-portal`); upstream: <pulled | NO_UPSTREAM>
- `tsc` errors, whole project: <N>
- `tsc` errors per touched file: <uniq -c lines, or "none">
- Not prettier-clean on the base (hand-format, never prettier): <list from Step 5>
- Pre-existing test failures (one file per run): <file → failing test names, or "none">
- Missing: <files printed MISSING, or "none">

### Insights checklist

- [x] I0: sync, baselines, track
- [ ] I1: Overview controls hidden on read-only surfaces (I-6)
- [ ] I2: InsightSurface model + context
- [ ] I3: share readers take the surface
- [ ] I4: page bodies moved, hrefs from basePath, route resolver
- [ ] I5: tab rules + InsightSurfaceLayout (share uses it)
- [ ] I6: BFF insight allowlist + middleware regex
- [ ] I7: analytics helpers
- [ ] I8: insight-info rules + server fetch + Insights in the nav
- [ ] I9: portal Insights route
- [ ] I10: "Sample data" pill
- [ ] I11: Clients column in Insights Tabs
- [ ] I12: Preview as client
- [ ] I13: theme / token pass
- [ ] I14: gates, manual pass, Lark rows, contract reconciliation
```

Session log entry (append at the end of the file):

```markdown
### 2026-10-07 — daffa (Insights plan executor)
- Insights Task 0: baselines recorded in "Insights (plan 2026-10-07)".
```

Fill the `<…>` placeholders from Steps 1–6. Nothing may stay in angle brackets.

- [ ] **Step 8: Commit**

```bash
cd WT && /usr/bin/git add docs/tracks/client-portal.track.md && /usr/bin/git commit -F - <<'EOF'
docs(web): open the Insights section of the client-portal track

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 1: Hide Review Signal, Ask a follow-up and refresh on read-only surfaces (I-6, §4.4)

**Files:**
- Modify: `src/components/brands/insight/DailySummaryOverview.tsx`
- Test: `src/components/brands/insight/DailySummaryOverview.test.tsx` (create)

**Interfaces:**
- Consumes: `useIsPublicView()` and `PublicShareProvider` from `@/context/PublicShareContext` (unchanged API).
- Produces: `DailySummaryOverview` renders no buttons inside any `PublicShareProvider`. Its props are unchanged, so `OverviewHomeContent` still passes its handlers; they are simply never reachable on a read-only surface.

Why inside the component: `OverviewHomeContent` always renders it with live handlers (`router.push('/brands/{id}/insight/signals')`, `openChatPanel()`). Hiding here covers the share link, the portal and the preview, because all three render it inside a `PublicShareProvider`.

- [ ] **Step 1: Write the failing test**

Create `src/components/brands/insight/DailySummaryOverview.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { cleanup, render, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PublicShareProvider } from "@/context/PublicShareContext";

import { DailySummaryOverview } from "./DailySummaryOverview";

// Named mutation (plan Task 1): replace `useIsPublicView()` with `false` in
// DailySummaryOverview → "hides them on a read-only surface…" fails (three
// buttons appear).

const body = () => within(document.body);

function props() {
  return {
    summary: "Engagement rose 12% this week.",
    generatedAt: "2026-10-07T03:00:00.000Z",
    onRefresh: vi.fn(),
    onReviewSignal: vi.fn(),
    onFollowUp: vi.fn(),
    kpiCards: [],
    renderKpiCard: () => null,
  };
}

describe("DailySummaryOverview (spec 2026-10-07 I-6)", () => {
  afterEach(() => cleanup());

  it("offers Review Signal, Ask a follow-up and refresh in the app", () => {
    render(<DailySummaryOverview {...props()} />);
    expect(
      body().getByRole("button", { name: /Review Signal/ })
    ).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: /Ask a follow-up/ })
    ).toBeInTheDocument();
    expect(body().getByTitle("Refresh summary")).toBeInTheDocument();
  });

  it("hides them on a read-only surface but keeps the summary and its time", () => {
    render(
      <PublicShareProvider
        slug="acme"
        brandId="b1"
        brandName="Acme"
        brandLogo={null}
        accessToken={null}
      >
        <DailySummaryOverview {...props()} />
      </PublicShareProvider>
    );
    expect(
      body().getByText("Engagement rose 12% this week.")
    ).toBeInTheDocument();
    expect(body().getByText(/^Generated at /)).toBeInTheDocument();
    expect(body().queryAllByRole("button")).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run it — FAIL**

Run: `cd WT && bun test src/components/brands/insight/DailySummaryOverview.test.tsx`
Expected: the first test PASSES. The second FAILS with `expected length 0, received 3`, because the buttons are rendered today.
- If the file dies at import (`1 error`), read the message before going on. `react-markdown` is ESM, and bun loads it; any other import error is real.

- [ ] **Step 3: Implement**

In `src/components/brands/insight/DailySummaryOverview.tsx`:

(a) Add the import below the `InsightPageHero` import:

```tsx
import { useIsPublicView } from "@/context/PublicShareContext";
```

(b) Replace

```tsx
}: DailySummaryOverviewProps) {
  if (!summary) return null;
```

with

```tsx
}: DailySummaryOverviewProps) {
  // Read-only surfaces (the public share link, the client portal, the
  // agency's client preview) keep the summary but none of its agency
  // actions: Review Signal routes into the app, Ask a follow-up opens the
  // chat, and refresh re-runs the summary (spec 2026-10-07 I-6).
  const readOnly = useIsPublicView();
  if (!summary) return null;
```

(c) Replace the refresh button block

```tsx
                <button
                  type="button"
                  onClick={onRefresh}
                  title="Refresh summary"
```

through its closing `</button>` with the same element wrapped in `{!readOnly && ( … )}`:

```tsx
                {!readOnly && (
                  <button
                    type="button"
                    onClick={onRefresh}
                    title="Refresh summary"
                    className="flex size-5 items-center justify-center rounded-full border border-white/5 bg-white/5 text-text-inverse-subtlest transition-colors hover:bg-white/10 hover:text-text-inverse"
                  >
                    <ArrowCounterClockwiseIcon size={10} />
                  </button>
                )}
```

(d) Replace `actions={` … `}` (the fragment with both buttons) with:

```tsx
        actions={
          readOnly ? undefined : (
            <>
              <button
                type="button"
                onClick={onReviewSignal}
                className={insightHeroActionClass}
              >
                <CellSignalFullIcon size={16} />
                Review Signal
              </button>
              <button
                type="button"
                onClick={onFollowUp}
                className={insightHeroActionClass}
              >
                <LightbulbIcon size={16} />
                Ask a follow-up
              </button>
            </>
          )
        }
```

`InsightPageHero` renders its actions row only when `actions` is truthy, so nothing is left behind.

- [ ] **Step 4: Run — PASS, then the named mutation**

Run: `cd WT && bun test src/components/brands/insight/DailySummaryOverview.test.tsx`
Expected: `2 pass`, `0 fail`.

Mutation: replace `useIsPublicView()` with `false`. Run again: the second test FAILS. Restore and run again: it PASSES.

- [ ] **Step 5: Lint, format, commit**

```bash
cd WT && F=(src/components/brands/insight/DailySummaryOverview.tsx src/components/brands/insight/DailySummaryOverview.test.tsx); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
fix(web): no Review Signal, Ask a follow-up or refresh on read-only Overviews

The public share link (and soon the client portal) rendered the Daily
Brand Summary's agency actions; they routed into the app and opened the
chat for a visitor with no session. Spec 2026-10-07 I-6.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 2: The `InsightSurface` model and its context

**Files:**
- Create: `src/lib/insight-surface/types.ts`
- Create: `src/services/insightSurface.ts`
- Test: `src/services/insightSurface.test.ts` (create)
- Modify: `src/context/PublicShareContext.tsx`
- Test: `src/context/PublicShareContext.test.tsx` (create)

**Interfaces:**
- Consumes: `axiosInstance`, `axiosPublic` (`@/services/axios`); `PORTAL_PROXY_BASE` (`@/services/client-portal`, `"/s/api/portal/"`).
- Produces (every later task uses these exact names):

```ts
// src/lib/insight-surface/types.ts
export type InsightAudience = "public" | "client" | "preview";

// src/services/insightSurface.ts
export interface InsightApi {
  client: AxiosInstance;
  prefix: string; // no trailing slash, e.g. "v1/share/brand/acme/insight"
  baseURL?: string; // per-call base (the portal BFF); omitted = the client's own
  headers?: Record<string, string>;
}
export interface InsightSurface {
  api: InsightApi;
  basePath: string; // "/share/brand/acme" | "/s/fcn/acme/insights" | "/brands/b1/settings/insights-tabs/preview"
  cacheKey: string; // "acme" on /share (so its query keys do not change)
  audience: InsightAudience;
}
export function shareInsightSurface(slug: string, accessToken?: string | null): InsightSurface;
export function portalInsightSurface(workspaceSlug: string, brandSlug: string): InsightSurface;
export function previewInsightSurface(brandId: string): InsightSurface;
export function insightRequest(api: InsightApi, params?: Record<string, unknown>): AxiosRequestConfig;
export function insightGet<T = any>(api: InsightApi, path: string, params?: Record<string, unknown>): Promise<T>;
export function insightPost<T = any>(api: InsightApi, path: string, body: unknown): Promise<T>;
export function insightHref(surface: Pick<InsightSurface, "basePath">, sub?: string): string;

// src/context/PublicShareContext.tsx (added)
//   PublicShareContextType.surface: InsightSurface
//   PublicShareProvider prop `surface?: InsightSurface`
export const useInsightSurface: () => InsightSurface | null;
```

- [ ] **Step 1: Write the failing surface test**

Create `src/services/insightSurface.test.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

import axiosInstance, { axiosPublic } from "@/services/axios";
import { PORTAL_PROXY_BASE } from "@/services/client-portal";

import {
  insightGet,
  insightHref,
  insightPost,
  insightRequest,
  portalInsightSurface,
  previewInsightSurface,
  shareInsightSurface,
} from "./insightSurface";

// Named mutations (plan Task 2):
// - drop encodeURIComponent in portalInsightSurface → "encodes the portal slugs"
// - cacheKey `share:${slug}` → "keeps the share cache key the bare slug"
// - always spread `baseURL: api.baseURL` → "adds no baseURL off the portal"
// - `sub.replace(/^\//, "")` (one slash) → "joins a sub-path once"
// - send `{ "X-Share-Token": accessToken ?? "" }` → "sends no token header on an open link"

describe("shareInsightSurface (spec 2026-10-07 §4.1)", () => {
  it("talks to the share api with the link's token", () => {
    const s = shareInsightSurface("acme", "tok");
    expect(s.api.client).toBe(axiosPublic);
    expect(s.api.prefix).toBe("v1/share/brand/acme/insight");
    expect(s.api.headers).toEqual({ "X-Share-Token": "tok" });
    expect(s.api.baseURL).toBeUndefined();
    expect(s.basePath).toBe("/share/brand/acme");
    expect(s.audience).toBe("public");
  });

  it("keeps the share cache key the bare slug", () => {
    expect(shareInsightSurface("acme", null).cacheKey).toBe("acme");
  });

  it("sends no token header on an open link", () => {
    expect(shareInsightSurface("acme", null).api.headers).toBeUndefined();
    expect(shareInsightSurface("acme", "").api.headers).toBeUndefined();
    expect(shareInsightSurface("acme").api.headers).toBeUndefined();
  });
});

describe("portalInsightSurface", () => {
  it("goes through the same-origin BFF, with no token", () => {
    const s = portalInsightSurface("fcn", "frndglow");
    expect(s.api.client).toBe(axiosPublic);
    expect(s.api.baseURL).toBe(PORTAL_PROXY_BASE);
    expect(s.api.prefix).toBe("fcn/frndglow/insight");
    expect(s.api.headers).toBeUndefined();
    expect(s.basePath).toBe("/s/fcn/frndglow/insights");
    expect(s.cacheKey).toBe("portal:fcn/frndglow");
    expect(s.audience).toBe("client");
  });

  it("encodes the portal slugs", () => {
    const s = portalInsightSurface("a b", "c/d");
    expect(s.api.prefix).toBe("a%20b/c%2Fd/insight");
    expect(s.basePath).toBe("/s/a%20b/c%2Fd/insights");
  });
});

describe("previewInsightSurface", () => {
  it("reads as the signed-in agency user", () => {
    const s = previewInsightSurface("b1");
    expect(s.api.client).toBe(axiosInstance);
    expect(s.api.prefix).toBe("v1/brands/b1/client-preview/insight");
    expect(s.api.baseURL).toBeUndefined();
    expect(s.basePath).toBe("/brands/b1/settings/insights-tabs/preview");
    expect(s.cacheKey).toBe("preview:b1");
    expect(s.audience).toBe("preview");
  });
});

describe("insightHref", () => {
  const s = { basePath: "/s/fcn/frndglow/insights" };
  it("is the base for the overview", () => {
    expect(insightHref(s)).toBe("/s/fcn/frndglow/insights");
    expect(insightHref(s, "")).toBe("/s/fcn/frndglow/insights");
  });
  it("joins a sub-path once", () => {
    expect(insightHref(s, "/paid-media")).toBe(
      "/s/fcn/frndglow/insights/paid-media"
    );
    expect(insightHref(s, "//signals/42")).toBe(
      "/s/fcn/frndglow/insights/signals/42"
    );
  });
});

describe("insightRequest / insightGet / insightPost", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("adds no baseURL off the portal", () => {
    const config = insightRequest(shareInsightSurface("acme", "tok").api);
    expect(Object.keys(config)).toEqual(["headers"]);
    expect(config.headers).toEqual({ "X-Share-Token": "tok" });
  });

  it("passes params, headers and the BFF base", async () => {
    const get = vi
      .spyOn(axiosPublic, "get")
      .mockResolvedValue({ data: { ok: 1 } } as never);
    const api = portalInsightSurface("fcn", "frndglow").api;
    await expect(
      insightGet(api, "atl/detail", { start_date: "2026-01-01" })
    ).resolves.toEqual({ ok: 1 });
    const [url, config] = get.mock.calls[0] as [string, Record<string, unknown>];
    expect(url).toBe("fcn/frndglow/insight/atl/detail");
    expect(config.params).toEqual({ start_date: "2026-01-01" });
    expect(config.baseURL).toBe("/s/api/portal/");
    expect(config.headers).toBeUndefined();
  });

  it("posts a body with the share token", async () => {
    const post = vi
      .spyOn(axiosPublic, "post")
      .mockResolvedValue({ data: { data: { rows: [] } } } as never);
    const api = shareInsightSurface("acme", "tok").api;
    await insightPost(api, "reports/query", { brandId: "b1", spec: {} });
    expect(post).toHaveBeenCalledWith(
      "v1/share/brand/acme/insight/reports/query",
      { brandId: "b1", spec: {} },
      { headers: { "X-Share-Token": "tok" } }
    );
  });
});
```

- [ ] **Step 2: Run it — FAIL**

Run: `cd WT && bun test src/services/insightSurface.test.ts`
Expected: `1 error` with `Cannot find module './insightSurface'`.

- [ ] **Step 3: Implement the model**

Create `src/lib/insight-surface/types.ts`:

```ts
/**
 * Who is reading a read-only insight surface (spec 2026-10-07 §4.1):
 * - "public": the brand's public share link (`/share/brand/{slug}`);
 * - "client": a signed-in client in the portal (`/s/{ws}/{brand}/insights`);
 * - "preview": the agency previewing what clients see (Brand Settings).
 * Every audience is read-only; "client" and "preview" see only the tabs
 * ticked under Clients.
 */
export type InsightAudience = "public" | "client" | "preview";
```

Create `src/services/insightSurface.ts`:

```ts
/**
 * Read-only insight surfaces (spec 2026-10-07 §4.1, I-1). A surface says
 * where one set of insight pages reads its data and where its links point:
 *
 * - the public share link → `v1/share/brand/{slug}/insight/*` with the
 *   link's `X-Share-Token`;
 * - the client portal → the same paths under the same-origin BFF
 *   (`/s/api/portal/{ws}/{brand}/insight/*`), whose route handler adds the
 *   client session from its HttpOnly cookie — no token in page JS;
 * - the agency's client preview → `v1/brands/{id}/client-preview/insight/*`
 *   with the signed-in user's own session.
 *
 * The readers in `services/query.ts`, `labelling/api.ts` and
 * `creative-analysis/api.ts` take an `InsightApi`; nothing else changes
 * between surfaces.
 */
import type { AxiosInstance, AxiosRequestConfig } from "axios";

import type { InsightAudience } from "@/lib/insight-surface/types";
import axiosInstance, { axiosPublic } from "@/services/axios";
import { PORTAL_PROXY_BASE } from "@/services/client-portal";

export type { InsightAudience };

export interface InsightApi {
  client: AxiosInstance;
  /** Path before every insight endpoint, no trailing slash. */
  prefix: string;
  /** Per-call base URL (the portal BFF); omitted = the client's own. */
  baseURL?: string;
  headers?: Record<string, string>;
}

export interface InsightSurface {
  api: InsightApi;
  /** Where the surface's pages live; tab and detail hrefs hang off it. */
  basePath: string;
  /** Query-key segment. The bare slug on /share, so its cache keys do not change. */
  cacheKey: string;
  audience: InsightAudience;
}

export function shareInsightSurface(
  slug: string,
  accessToken?: string | null
): InsightSurface {
  return {
    api: {
      client: axiosPublic,
      prefix: `v1/share/brand/${slug}/insight`,
      headers: accessToken ? { "X-Share-Token": accessToken } : undefined,
    },
    basePath: `/share/brand/${slug}`,
    cacheKey: slug,
    audience: "public",
  };
}

export function portalInsightSurface(
  workspaceSlug: string,
  brandSlug: string
): InsightSurface {
  const ws = encodeURIComponent(workspaceSlug);
  const brand = encodeURIComponent(brandSlug);
  return {
    api: {
      client: axiosPublic,
      baseURL: PORTAL_PROXY_BASE,
      prefix: `${ws}/${brand}/insight`,
    },
    basePath: `/s/${ws}/${brand}/insights`,
    cacheKey: `portal:${workspaceSlug}/${brandSlug}`,
    audience: "client",
  };
}

export function previewInsightSurface(brandId: string): InsightSurface {
  return {
    api: {
      client: axiosInstance,
      prefix: `v1/brands/${brandId}/client-preview/insight`,
    },
    basePath: `/brands/${brandId}/settings/insights-tabs/preview`,
    cacheKey: `preview:${brandId}`,
    audience: "preview",
  };
}

/** The axios config every reader sends: params, the surface's headers, its base. */
export function insightRequest(
  api: InsightApi,
  params?: Record<string, unknown>
): AxiosRequestConfig {
  return {
    ...(params !== undefined ? { params } : {}),
    headers: api.headers,
    ...(api.baseURL ? { baseURL: api.baseURL } : {}),
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- the share payloads are untyped today; readers narrow at their call sites
export async function insightGet<T = any>(
  api: InsightApi,
  path: string,
  params?: Record<string, unknown>
): Promise<T> {
  const response = await api.client.get<T>(
    `${api.prefix}/${path}`,
    insightRequest(api, params)
  );
  return response.data;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- see insightGet
export async function insightPost<T = any>(
  api: InsightApi,
  path: string,
  body: unknown
): Promise<T> {
  const response = await api.client.post<T>(
    `${api.prefix}/${path}`,
    body,
    insightRequest(api)
  );
  return response.data;
}

/** `/s/fcn/acme/insights` + `"/paid-media"` → `/s/fcn/acme/insights/paid-media`. */
export function insightHref(
  surface: Pick<InsightSurface, "basePath">,
  sub = ""
): string {
  const tail = sub.replace(/^\/+/, "");
  return tail ? `${surface.basePath}/${tail}` : surface.basePath;
}
```

If eslint reports the two `eslint-disable-next-line` comments as unused (the rule may be off in this repo), delete them.

- [ ] **Step 4: Run — PASS, then the named mutations**

Run: `cd WT && bun test src/services/insightSurface.test.ts`
Expected: every test passes. Apply each mutation from the file header, one at a time. Each must fail the named test. Restore after each.

- [ ] **Step 5: Write the failing context test**

Create `src/context/PublicShareContext.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { cleanup, render, within } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { portalInsightSurface } from "@/services/insightSurface";

import {
  PublicShareProvider,
  useInsightSurface,
  useIsPublicView,
} from "./PublicShareContext";

// Named mutation (plan Task 2): build `shareInsightSurface(slug, accessToken)`
// even when a `surface` prop is passed → "uses the surface it is given".

const body = () => within(document.body);

function Probe() {
  const s = useInsightSurface();
  const publicView = useIsPublicView();
  return (
    <p data-testid="probe">
      {s
        ? `${s.audience}|${s.basePath}|${s.api.prefix}|${s.cacheKey}|${JSON.stringify(s.api.headers ?? null)}|${publicView}`
        : `none|${publicView}`}
    </p>
  );
}

const shared = {
  slug: "acme",
  brandId: "b1",
  brandName: "Acme",
  brandLogo: null,
};

describe("PublicShareContext carries the insight surface (spec 2026-10-07 §4.1)", () => {
  afterEach(() => cleanup());

  it("builds the share surface from the slug and token by default", () => {
    render(
      <PublicShareProvider {...shared} accessToken="tok">
        <Probe />
      </PublicShareProvider>
    );
    expect(body().getByTestId("probe")).toHaveTextContent(
      'public|/share/brand/acme|v1/share/brand/acme/insight|acme|{"X-Share-Token":"tok"}|true'
    );
  });

  it("uses the surface it is given", () => {
    render(
      <PublicShareProvider
        {...shared}
        accessToken={null}
        surface={portalInsightSurface("fcn", "frndglow")}
      >
        <Probe />
      </PublicShareProvider>
    );
    expect(body().getByTestId("probe")).toHaveTextContent(
      "client|/s/fcn/frndglow/insights|fcn/frndglow/insight|portal:fcn/frndglow|null|true"
    );
  });

  it("is absent outside a read-only surface", () => {
    render(<Probe />);
    expect(body().getByTestId("probe")).toHaveTextContent("none|false");
  });
});
```

- [ ] **Step 6: Run it — FAIL**

Run: `cd WT && bun test src/context/PublicShareContext.test.tsx`
Expected: a type-free runtime failure: `useInsightSurface is not a function` (or an import error naming it).

- [ ] **Step 7: Implement the context**

In `src/context/PublicShareContext.tsx`:

(a) Replace

```tsx
import { createContext, useContext, ReactNode } from "react";
```

with

```tsx
import { createContext, useContext, useMemo, ReactNode } from "react";

import {
  shareInsightSurface,
  type InsightSurface,
} from "@/services/insightSurface";
```

(b) In `interface PublicShareContextType`, after `isPublicView: true; // Always true when inside this context`, add:

```tsx
  /**
   * Where this read-only surface reads its data and where its links point
   * (spec 2026-10-07 §4.1) — the public share link, the client portal, or
   * the agency's client preview.
   */
  surface: InsightSurface;
```

(c) After `useIsPublicView`, add:

```tsx
/**
 * The read-only insight surface this component renders on, or null outside
 * one (the authenticated app).
 */
export const useInsightSurface = (): InsightSurface | null =>
  useContext(PublicShareContext)?.surface ?? null;
```

(d) In `interface PublicShareProviderProps`, after `ownedMediaTableView?: OwnedMediaTableView | null;`, add:

```tsx
  /** Defaults to the public share surface of `slug` + `accessToken`. */
  surface?: InsightSurface;
```

(e) Replace the provider body with:

```tsx
export const PublicShareProvider = ({
  slug,
  brandId,
  brandName,
  brandLogo,
  accessToken,
  ownedMediaTableView = null,
  surface,
  children,
}: PublicShareProviderProps) => {
  const resolvedSurface = useMemo(
    () => surface ?? shareInsightSurface(slug, accessToken),
    [surface, slug, accessToken]
  );
  return (
    <PublicShareContext.Provider
      value={{
        slug,
        brandId,
        brandName,
        brandLogo,
        accessToken,
        ownedMediaTableView,
        isPublicView: true,
        surface: resolvedSurface,
      }}
    >
      {children}
    </PublicShareContext.Provider>
  );
};
```

`src/app/share/dashboard/[slug]/page.tsx` keeps passing the same props and so gets the share surface of its slug. That is exactly what its readers used before.

- [ ] **Step 8: Run — PASS, the mutation, and the neighbours**

```bash
cd WT && bun test src/context/PublicShareContext.test.tsx && bun test "src/app/share/dashboard/[slug]/page.test.tsx" && bun test src/components/brands/insight/DailySummaryOverview.test.tsx
```

Expected:
- the context test passes;
- the dashboard-share page test shows exactly its Task 0 result;
- the Task 1 test still passes.

Mutation: make `resolvedSurface` always `shareInsightSurface(slug, accessToken)`. "uses the surface it is given" FAILS. Restore.

- [ ] **Step 9: Lint, format, commit**

```bash
cd WT && F=(src/lib/insight-surface/types.ts src/services/insightSurface.ts src/services/insightSurface.test.ts src/context/PublicShareContext.tsx src/context/PublicShareContext.test.tsx); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): InsightSurface — one read-only insight surface, three transports

The public share link, the client portal (through the BFF) and the
agency's client preview differ only in where they read and where their
links point. PublicShareContext now carries that surface; its provider
still builds the share surface from slug + token, so nothing reading it
changes. Spec 2026-10-07 §4.1.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 3: The share readers take the surface (no change on /share)

**Files:**
- Modify: `src/services/query.ts` (the "Brand Public Share" readers, `shareHeaders` … `getBrandShareATLFilters`)
- Modify: `src/services/labelling/api.ts`, `src/services/labelling/hooks.ts`
- Modify: `src/services/creative-analysis/api.ts`, `src/services/creative-analysis/hooks.ts`
- Modify: `src/hooks/useCustomReports.ts` (hand-format), `src/hooks/useReportTemplates.ts`
- Modify: `src/components/brands/CampaignContent.tsx` (hand-format), `src/components/brands/insight/PaidMediaContent.tsx`, `src/components/brands/insight/SentimentAnalysis.tsx`, `src/components/signal-trends/SignalTrendsListContent.tsx`, `src/components/signal-detail/SignalDetailContent.tsx`
- Modify: `src/app/share/brand/[slug]/page.tsx`, `atl/page.tsx`, `earned-media/page.tsx`, `owned-media/page.tsx`, `paid-media/page.tsx`, `campaigns/page_old_jeff.tsx`
- Test: `src/services/insightReaders.test.ts` (create)

**Interfaces:**
- Consumes: `InsightApi`, `insightGet`, `insightPost`, `insightRequest`, `shareInsightSurface`, `portalInsightSurface` (Task 2); `usePublicShare()` with its `surface` (Task 2).
- Produces:
  - every `getBrandShare*` / `postBrandShareReportQuery` takes `api: InsightApi` FIRST, then its old non-slug, non-token arguments, in the same order;
  - `LabelShareContext` and `CreativeShareContext` become aliases of `InsightApi`;
  - `getBrandShareInfo(slug)` and `shareHeaders(accessToken)` are unchanged.

| Reader | New signature |
|---|---|
| `getBrandShareOverview` | `(api)` |
| `getBrandShareHome` | `(api)` |
| `getBrandShareSignals` | `(api, params?)` |
| `getBrandShareSignalDetail` | `(api, signalId)` |
| `getBrandShareReports` | `(api)` |
| `getBrandShareReport` | `(api, reportId)` |
| `postBrandShareReportQuery` | `(api, body)` |
| `getBrandShareReportTemplates` | `(api)` |
| `getBrandShareCampaign`, `getBrandShareCampaignFilters`, `getBrandSharePaidMedia{Overview,Detail,Filters}`, `getBrandShareOwnedMedia{Overview,Detail,Filters}`, `getBrandShareEarnedMedia`, `getBrandShareEarnedMedia{Influencers,Filters}`, `getBrandShareATL{Overview,Detail,Filters}` | `(api, params?)` |
| `getBrandShareOwnedMediaSentiment` | `(api, params?)`, returning `Promise<OwnedMediaShareSentimentResponse>` |
| `getLabelAttributes` | `(brandId, share?: InsightApi)` |
| `listPlaybooks` | `(brandId, tab, share?: InsightApi)` |
| `readPlaybook` | `(brandId, params, share?: InsightApi)` |
| `getAnalysisHistory` / `getCompletedAnalysis` | `(brandId, contentId, body, share?: InsightApi)` |

Query keys: every place that put `slug` in a share query key now puts `surface.cacheKey`, which equals the slug on /share.

- [ ] **Step 1: Write the failing wire table**

Create `src/services/insightReaders.test.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

import { axiosPublic } from "@/services/axios";
import {
  getAnalysisHistory,
  listPlaybooks,
  readPlaybook,
} from "@/services/creative-analysis/api";
import {
  portalInsightSurface,
  shareInsightSurface,
  type InsightApi,
} from "@/services/insightSurface";
import { getLabelAttributes } from "@/services/labelling/api";
import * as q from "@/services/query";

// Named mutations (plan Task 3):
// - misspell one path in query.ts (e.g. "owned-media/filter") → its row fails
// - drop `headers: api.headers` from insightRequest → every share row fails
// - pass `undefined` instead of `params` in one reader → that row's params check fails
// - build signals' query string with URLSearchParams(params) → "keeps the signals query string"

const share = shareInsightSurface("acme", "tok").api;
const TOKEN = { "X-Share-Token": "tok" };

type Row = [
  name: string,
  call: (api: InsightApi) => Promise<unknown>,
  path: string,
  params?: Record<string, unknown>,
];

const P = { start_date: "2026-01-01", end_date: "2026-01-31" };

const GETS: Row[] = [
  ["overview", (api) => q.getBrandShareOverview(api), "overview"],
  ["home", (api) => q.getBrandShareHome(api), "home"],
  ["signal detail", (api) => q.getBrandShareSignalDetail(api, "42"), "signals/42"],
  ["reports", (api) => q.getBrandShareReports(api), "reports"],
  ["report", (api) => q.getBrandShareReport(api, "r1"), "reports/r1"],
  ["report templates", (api) => q.getBrandShareReportTemplates(api), "report-templates"],
  ["campaign", (api) => q.getBrandShareCampaign(api, { campaign_name: "Q4" }), "campaign", { campaign_name: "Q4" }],
  ["campaign filters", (api) => q.getBrandShareCampaignFilters(api, P), "campaign/filters", P],
  ["paid overview", (api) => q.getBrandSharePaidMediaOverview(api, P), "paid-media/overview", P],
  ["paid detail", (api) => q.getBrandSharePaidMediaDetail(api, P), "paid-media/detail", P],
  ["paid filters", (api) => q.getBrandSharePaidMediaFilters(api, P), "paid-media/filters", P],
  ["owned overview", (api) => q.getBrandShareOwnedMediaOverview(api, P), "owned-media/overview", P],
  ["owned detail", (api) => q.getBrandShareOwnedMediaDetail(api, P), "owned-media/detail", P],
  ["owned sentiment", (api) => q.getBrandShareOwnedMediaSentiment(api, { platform: "tiktok" }), "owned-media/sentiment", { platform: "tiktok" }],
  ["owned filters", (api) => q.getBrandShareOwnedMediaFilters(api, P), "owned-media/filters", P],
  ["earned", (api) => q.getBrandShareEarnedMedia(api, P), "earned-media", P],
  ["earned influencers", (api) => q.getBrandShareEarnedMediaInfluencers(api, P), "earned-media/influencers", P],
  ["earned filters", (api) => q.getBrandShareEarnedMediaFilters(api, P), "earned-media/filters", P],
  ["atl overview", (api) => q.getBrandShareATLOverview(api, P), "atl/overview", P],
  ["atl detail", (api) => q.getBrandShareATLDetail(api, P), "atl/detail", P],
  ["atl filters", (api) => q.getBrandShareATLFilters(api, P), "atl/filters", P],
  ["label attributes", (api) => getLabelAttributes("b1", api), "owned-media/label-attributes"],
  ["playbooks", (api) => listPlaybooks("b1", "owned", api), "owned-media/creative/playbooks", { tab: "owned" }],
  [
    "playbook",
    (api) =>
      readPlaybook(
        "b1",
        { tab: "owned", objective: "awareness", dimensions: [], platform: null },
        api
      ),
    "owned-media/creative/playbook",
    { tab: "owned", objective: "awareness", dimensions: [], platform: null },
  ],
  [
    "analysis history",
    (api) => getAnalysisHistory("b1", "c9", { dimensions: [], playbook_id: 7 }, api),
    "owned-media/content/c9/creative-analysis",
    { playbook_id: 7 },
  ],
];

function stubGet() {
  return vi
    .spyOn(axiosPublic, "get")
    .mockResolvedValue({ data: { data: [] } } as never);
}

describe("the share readers keep their wire calls (spec 2026-10-07 §4.1)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it.each(GETS)("%s", async (_name, call, path, params) => {
    const get = stubGet();
    await call(share);
    expect(get).toHaveBeenCalledTimes(1);
    const [url, config] = get.mock.calls[0] as [string, Record<string, unknown>];
    expect(url).toBe(`v1/share/brand/acme/insight/${path}`);
    expect(config.headers).toEqual(TOKEN);
    expect("baseURL" in config).toBe(false);
    if (params !== undefined) expect(config.params).toEqual(params);
  });

  it("keeps the signals query string", async () => {
    const get = stubGet();
    await q.getBrandShareSignals(share, {
      per_page: 10,
      page: 2,
      platform: "tiktok",
      recommendation: "all",
    });
    expect(get.mock.calls[0][0]).toBe(
      "v1/share/brand/acme/insight/signals?per_page=10&page=2&platform=tiktok"
    );
  });

  it("posts the report query with the share token", async () => {
    const post = vi
      .spyOn(axiosPublic, "post")
      .mockResolvedValue({ data: { data: { rows: [1] } } } as never);
    await expect(
      q.postBrandShareReportQuery(share, { brandId: "b1", spec: {} })
    ).resolves.toEqual({ rows: [1] });
    expect(post).toHaveBeenCalledWith(
      "v1/share/brand/acme/insight/reports/query",
      { brandId: "b1", spec: {} },
      { headers: TOKEN }
    );
  });

  it("sends no token header on an open link", async () => {
    const get = stubGet();
    await q.getBrandShareHome(shareInsightSurface("acme", null).api);
    const config = get.mock.calls[0][1] as Record<string, unknown>;
    expect(config.headers).toBeUndefined();
  });
});

describe("the same readers on the portal", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("go through the BFF with no token", async () => {
    const get = stubGet();
    const api = portalInsightSurface("fcn", "frndglow").api;
    await q.getBrandSharePaidMediaDetail(api, P);
    await getLabelAttributes("b1", api);
    expect(get.mock.calls.map((c) => c[0])).toEqual([
      "fcn/frndglow/insight/paid-media/detail",
      "fcn/frndglow/insight/owned-media/label-attributes",
    ]);
    for (const call of get.mock.calls) {
      const config = call[1] as Record<string, unknown>;
      expect(config.baseURL).toBe("/s/api/portal/");
      expect(config.headers).toBeUndefined();
    }
  });
});
```

`prettier --write` in Step 6 reflows the long rows; that is expected. Check the file stays < 45 KB.

- [ ] **Step 2: Run it — FAIL**

Run: `cd WT && bun test src/services/insightReaders.test.ts`
Expected: almost every row fails, because the readers still take a slug. A row receiving an `InsightApi` object as `slug` builds `v1/share/brand/[object Object]/…`.

- [ ] **Step 3: Rewrite the readers in `src/services/query.ts`**

(a) Add to the imports at the top of the file, after `import axiosInstance, { axiosPublic } from "./axios";`:

```ts
import { insightGet, insightPost, type InsightApi } from "./insightSurface";
```

(b) Replace everything from the doc comment above `export const shareHeaders` down to the end of `getBrandShareATLFilters` (the last reader before `export const getBrandShareSettings`) with:

```ts
/**
 * Build headers with the share access token if provided. Kept for callers
 * outside the insight surface; the readers below get their headers from
 * their `InsightApi` (see `services/insightSurface.ts`).
 */
export const shareHeaders = (accessToken?: string) =>
  accessToken ? { "X-Share-Token": accessToken } : undefined;

/*
 * Read-only insight readers (spec 2026-10-07 §4.1). Each takes the
 * surface's `InsightApi` — the public share link, the client portal (BFF)
 * or the agency's client preview — and the path under `…/insight/`.
 * `shareInsightSurface(slug, token).api` reproduces the pre-surface calls
 * exactly (`services/insightReaders.test.ts`).
 */

export const getBrandShareOverview = (api: InsightApi) =>
  insightGet(api, "overview");

export const getBrandShareHome = (api: InsightApi) => insightGet(api, "home");

export const getBrandShareSignals = async (
  api: InsightApi,
  params?: {
    per_page?: number;
    page?: number;
    search?: string;
    platform?: string;
    recommendation?: string;
    is_bookmarked?: boolean;
    date_from?: string;
    date_to?: string;
  }
) => {
  const queryParams = new URLSearchParams();
  if (params?.per_page)
    queryParams.append("per_page", params.per_page.toString());
  if (params?.page) queryParams.append("page", params.page.toString());
  if (params?.search) queryParams.append("search", params.search);
  if (params?.platform && params.platform !== "all")
    queryParams.append("platform", params.platform);
  if (params?.recommendation && params.recommendation !== "all")
    queryParams.append("recommendation", params.recommendation);
  if (params?.is_bookmarked === true)
    queryParams.append("is_bookmarked", "true");
  if (params?.date_from) queryParams.append("date_from", params.date_from);
  if (params?.date_to) queryParams.append("date_to", params.date_to);

  const query = queryParams.toString();
  return insightGet(api, query ? `signals?${query}` : "signals");
};

export const getBrandShareSignalDetail = (api: InsightApi, signalId: string) =>
  insightGet(api, `signals/${signalId}`);

export const getBrandShareReports = async (api: InsightApi) => {
  const data = await insightGet(api, "reports");
  // BE returns `{ data: [...], meta: {...} }` — keep same shape as
  // getCustomReports return (array of CustomReport).
  return data?.data ?? data ?? [];
};

export const getBrandShareReport = async (api: InsightApi, reportId: string) => {
  const data = await insightGet(api, `reports/${reportId}`);
  return data?.data ?? data;
};

export const postBrandShareReportQuery = async (
  api: InsightApi,
  body: { brandId: string; spec: unknown }
) => {
  const data = await insightPost(api, "reports/query", body);
  return data?.data ?? data;
};

export const getBrandShareReportTemplates = async (api: InsightApi) => {
  const data = await insightGet(api, "report-templates");
  return data?.data ?? data ?? [];
};

export const getBrandShareCampaign = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "campaign", params);

export const getBrandShareCampaignFilters = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "campaign/filters", params);

export const getBrandSharePaidMediaOverview = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "paid-media/overview", params);

export const getBrandSharePaidMediaDetail = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "paid-media/detail", params);

export const getBrandSharePaidMediaFilters = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "paid-media/filters", params);

export const getBrandShareOwnedMediaOverview = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "owned-media/overview", params);

export const getBrandShareOwnedMediaDetail = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "owned-media/detail", params);

/**
 * Owned Media sentiment on the public share surface (CP-13).
 *
 * Narrower than the authenticated twin on purpose: it reads only dates,
 * `platform` and `label_filters`, and its response carries no campaign
 * options — a logged-out viewer never sees the brand's campaign taxonomy.
 */
export const getBrandShareOwnedMediaSentiment = (
  api: InsightApi,
  params?: {
    platform?: string;
    start_date?: string;
    end_date?: string;
    label_filters?: string;
  }
): Promise<OwnedMediaShareSentimentResponse> =>
  insightGet<OwnedMediaShareSentimentResponse>(
    api,
    "owned-media/sentiment",
    params
  );

export const getBrandShareOwnedMediaFilters = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "owned-media/filters", params);

export const getBrandShareEarnedMedia = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "earned-media", params);

export const getBrandShareEarnedMediaInfluencers = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "earned-media/influencers", params);

export const getBrandShareEarnedMediaFilters = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "earned-media/filters", params);

export const getBrandShareATLOverview = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "atl/overview", params);

export const getBrandShareATLDetail = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "atl/detail", params);

export const getBrandShareATLFilters = (
  api: InsightApi,
  params?: Record<string, unknown>
) => insightGet(api, "atl/filters", params);
```

The `params` typing of `getBrandShareOwnedMediaSentiment` is narrower than `Record<string, unknown>`, so `insightGet`'s `params` argument needs it as `Record<string, unknown>`. If tsc complains, pass `params as Record<string, unknown> | undefined`.

(c) `labelling/api.ts`: replace

```ts
import axiosInstance, { axiosPublic } from "../axios";
import { shareHeaders } from "@/services/query";
```

with

```ts
import axiosInstance from "../axios";
import { insightGet, type InsightApi } from "@/services/insightSurface";
```

replace the `LabelShareContext` interface (and its doc comment) with

```ts
/**
 * The read-only insight surface's api (spec 2026-10-07 §4.1) for READ-only
 * label lookups — the public share link, the client portal or the agency's
 * client preview. Undefined = the authenticated app.
 */
export type LabelShareContext = InsightApi;
```

and the `if (share) { … }` block of `getLabelAttributes` with

```ts
  if (share) {
    const data = await insightGet(share, "owned-media/label-attributes");
    return data.data;
  }
```

(d) `creative-analysis/api.ts`: replace

```ts
import axiosInstance, { axiosPublic } from "@/services/axios";
import { shareHeaders } from "@/services/query";
```

with

```ts
import axiosInstance from "@/services/axios";
import { insightRequest, type InsightApi } from "@/services/insightSurface";
```

Replace the `CreativeShareContext` interface and the `shareRequestConfig` helper with

```ts
/**
 * The read-only insight surface's api (spec 2026-10-07 §4.1). When
 * present, the READ endpoints route through that surface (share link,
 * client portal, client preview), so its viewer sees already-generated
 * playbooks/analyses. There is deliberately no surface path for
 * generate/regenerate/delete/analyze — those stay authenticated-only.
 */
export type CreativeShareContext = InsightApi;
```

Then edit three readers:
- In `listPlaybooks`, replace the `if (share) { … }` block with

```ts
  if (share) {
    const res = await share.client.get(
      `${share.prefix}/owned-media/creative/playbooks`,
      insightRequest(share, { tab })
    );
    return res.data;
  }
```

- In `readPlaybook`, replace its `if (share) { … }` block with

```ts
  if (share) {
    const res = await share.client.get(
      `${share.prefix}/owned-media/creative/playbook`,
      insightRequest(share, requestParams)
    );
    return res.data;
  }
```

- In `getAnalysisHistory`, replace the `share ? await axiosPublic.get(…) : …` expression's share branch with

```ts
    const res = share
      ? await share.client.get(
          `${share.prefix}/owned-media/content/${contentId}/creative-analysis`,
          insightRequest(share, params)
        )
      : await axiosInstance.get(
          `v1/brands/${brandId}/content/${contentId}/creative-analysis`,
          { params }
        );
```

- [ ] **Step 4: Run the wire table — PASS**

Run: `cd WT && bun test src/services/insightReaders.test.ts`
Expected: every row passes. Apply the four named mutations one at a time; each fails its named row(s). Restore after each.

- [ ] **Step 5: Move every caller onto the surface**

In each file below, `share` / `publicShare` / `publicCtx` / `ctx` is the existing `usePublicShare()` value. `.surface` exists on it since Task 2.

`src/services/labelling/hooks.ts`, in `useBrandLabelAttributes`, replace

```ts
  const share = usePublicShare();
  const shareArg = share
    ? { slug: share.slug, accessToken: share.accessToken }
    : undefined;
  return useQuery<LabelAttribute[]>({
    queryKey: [...labellingKeys.attributes(brandId), share?.slug ?? "auth"],
```

with

```ts
  const share = usePublicShare();
  const shareArg = share?.surface.api;
  return useQuery<LabelAttribute[]>({
    queryKey: [
      ...labellingKeys.attributes(brandId),
      share?.surface.cacheKey ?? "auth",
    ],
```

`src/services/creative-analysis/hooks.ts`:
- Replace `useCreativeShareContext` with

```ts
function useCreativeShareContext(): {
  api: CreativeShareContext | undefined;
  key: string;
} {
  const share = usePublicShare();
  return {
    api: share?.surface.api,
    key: share?.surface.cacheKey ?? "auth",
  };
}
```

- In `usePlaybookList`, `useReadPlaybook` and `useCompletedAnalysis`:
  - replace `const share = useCreativeShareContext();` with `const { api: share, key: shareKey } = useCreativeShareContext();`;
  - replace `share?.slug ?? "auth",` with `shareKey,`.

  The `listPlaybooks(…, share)`, `readPlaybook(…, share)` and `getCompletedAnalysis(…, share)` calls stay as written.

`src/hooks/useCustomReports.ts` (hand-format; never prettier). In each of `useCustomReports`, `useCustomReport` and `useReportQuery`:
- replace the two lines

```ts
  const slug = publicCtx?.slug ?? "";
  const accessToken = publicCtx?.accessToken ?? undefined;
```

  with

```ts
  const surface = publicCtx?.surface ?? null;
  const slug = surface?.cacheKey ?? "";
```

- then replace the reader calls:
  - `getBrandShareReports(slug, accessToken)` → `getBrandShareReports(surface!.api)`;
  - `getBrandShareReport(slug, reportId as string, accessToken)` → `getBrandShareReport(surface!.api, reportId as string)`;
  - the `postBrandShareReportQuery(` call →

```ts
        ? postBrandShareReportQuery(surface!.api, {
            brandId,
            spec: spec as CustomReportSpec,
          })
```

The query keys keep `slug` (now the cache key, which equals the slug on /share), and every `enabled` still reads `!!slug`.

`src/hooks/useReportTemplates.ts`: replace

```ts
  const slug = publicCtx?.slug ?? "";
  const accessToken = publicCtx?.accessToken ?? undefined;
```

with

```ts
  const surface = publicCtx?.surface ?? null;
  const slug = surface?.cacheKey ?? "";
```

and `getBrandShareReportTemplates(slug, accessToken)` with `getBrandShareReportTemplates(surface!.api)`.

`src/components/brands/CampaignContent.tsx` (hand-format): replace

```tsx
    queryKey: publicShare
      ? ["brandShareCampaignFilters", publicShare.slug]
      : ["campaignFilters", brandId],
    queryFn: () =>
      publicShare
        ? getBrandShareCampaignFilters(
            publicShare.slug,
            undefined,
            publicShare.accessToken ?? undefined
          )
        : getCampaignFilters(brandId, { workspaceId, uniqueCode }),
```

with

```tsx
    queryKey: publicShare
      ? ["brandShareCampaignFilters", publicShare.surface.cacheKey]
      : ["campaignFilters", brandId],
    queryFn: () =>
      publicShare
        ? getBrandShareCampaignFilters(publicShare.surface.api)
        : getCampaignFilters(brandId, { workspaceId, uniqueCode }),
```

`src/components/brands/insight/PaidMediaContent.tsx`:
- `const useShareFiltersRoute = isPublicView && Boolean(publicShare?.slug);` → `const useShareFiltersRoute = isPublicView && Boolean(publicShare?.surface);`
- `useShareFiltersRoute ? \`share:${publicShare?.slug}\` : "auth",` → `useShareFiltersRoute ? \`share:${publicShare?.surface.cacheKey}\` : "auth",`
- the share branch becomes

```tsx
      if (useShareFiltersRoute && publicShare) {
        return getBrandSharePaidMediaFilters(publicShare.surface.api, {
          start_date: formattedFilterDates.startDate,
          end_date: formattedFilterDates.endDate,
        });
      }
```

`src/components/brands/insight/SentimentAnalysis.tsx`: replace

```tsx
  const shareSlug = share?.slug;
```

with

```tsx
  const shareSurface = share?.surface ?? null;
  const shareSlug = shareSurface?.cacheKey;
```

and the `queryFn` with

```tsx
      queryFn: () =>
        getBrandShareOwnedMediaSentiment(shareSurface!.api, {
          platform: platformSelected !== "all" ? platformSelected : undefined,
          start_date: formattedStartDate,
          end_date: formattedEndDate,
          label_filters: shareLabelFiltersParam,
        }),
```

The query key and `enabled` keep `shareSlug`.

`src/components/signal-trends/SignalTrendsListContent.tsx`: replace

```tsx
  const slug = publicCtx?.slug ?? "";
  const accessToken = publicCtx?.accessToken ?? undefined;
```

with

```tsx
  const shareSurface = publicCtx?.surface ?? null;
  const slug = publicCtx?.slug ?? "";
```

Then make three replacements:
- `isPublicView ? slug : brandId,` (in the query key) → `isPublicView ? (shareSurface?.cacheKey ?? "") : brandId,`;
- the share call → `getBrandShareSignals(shareSurface!.api, { per_page: itemsPerPage, page: currentPage, search: debouncedSearch.trim() || undefined, platform, recommendation: apiRecommendation })`, laid out over several lines the way prettier writes it;
- `enabled: isPublicView ? !!slug : !!brandId,` → `enabled: isPublicView ? !!shareSurface : !!brandId,`.

`slug` stays only for the detail href, which Task 4 replaces.

`src/components/signal-detail/SignalDetailContent.tsx`: replace

```tsx
  const slug = publicCtx?.slug ?? "";
  const accessToken = publicCtx?.accessToken ?? undefined;
```

with

```tsx
  const shareSurface = publicCtx?.surface ?? null;
  const slug = shareSurface?.cacheKey ?? "";
```

and `getBrandShareSignalDetail(slug, signalId, accessToken)` with `getBrandShareSignalDetail(shareSurface!.api, signalId)`.

The share pages:
- `src/app/share/brand/[slug]/page.tsx`: replace

```tsx
  const slug = ctx?.slug ?? "";
  const accessToken = ctx?.accessToken ?? undefined;

  const { data, isLoading, isError, error, refetch } =
    useQuery<HomeInsightsResponse>({
      queryKey: ["brand-share-home", slug],
      queryFn: () => getBrandShareHome(slug, accessToken),
      retry: false,
      enabled: !!slug,
    });
```

  with

```tsx
  const surface = ctx?.surface ?? null;

  const { data, isLoading, isError, error, refetch } =
    useQuery<HomeInsightsResponse>({
      queryKey: ["brand-share-home", surface?.cacheKey ?? ""],
      queryFn: () => getBrandShareHome(surface!.api),
      retry: false,
      enabled: !!surface,
    });
```

- `atl/page.tsx`, `earned-media/page.tsx`, `owned-media/page.tsx`, `paid-media/page.tsx`, `campaigns/page_old_jeff.tsx`:
  - In the destructure after `if (!ctx) return null;`, drop `slug` and `accessToken` and add `surface`. For example, `const { slug, accessToken, brandId } = ctx;` → `const { surface, brandId } = ctx;`, and `const { slug, accessToken } = ctx;` → `const { surface } = ctx;`.
  - Then, in every `useQuery` of the file:
    - replace `slug,` inside the `queryKey` array with `surface.cacheKey,`;
    - rewrite the reader call so the api comes first and the token goes, as listed below.

  The reader calls, file by file:
  - `atl`:
    - `getBrandShareATLOverview(surface.api)`;
    - `getBrandShareATLDetail(surface.api, { startDate: formattedDates.startDate, endDate: formattedDates.endDate })`;
    - `getBrandShareATLFilters(surface.api)`.
  - `earned-media`:
    - `getBrandShareEarnedMedia(surface.api)`;
    - `getBrandShareEarnedMediaFilters(surface.api)`.
  - `owned-media`:
    - `getBrandShareOwnedMediaOverview(surface.api, labelFiltersParam ? { label_filters: labelFiltersParam } : undefined)`;
    - `getBrandShareOwnedMediaDetail(surface.api, { start_date: …, end_date: …, ...(labelFiltersParam ? { label_filters: labelFiltersParam } : {}) })`. Keep the existing comment above it.
    - `getBrandShareOwnedMediaFilters(surface.api, labelFiltersParam ? { label_filters: labelFiltersParam } : undefined)`.
  - `paid-media`:
    - `getBrandSharePaidMediaOverview(surface.api, { start_date: …, end_date: … })`;
    - `getBrandSharePaidMediaDetail(surface.api, { start_date: …, end_date: …, ...parsedFilters })`.
  - `page_old_jeff`:
    - `getBrandShareCampaign(surface.api, { campaign_name: selectedCampaign || undefined })`.

  ATL's detail keeps its camelCase keys exactly as today: fixing them is out of scope, and "no change on /share".

- [ ] **Step 6: Nothing still passes a slug to a reader**

```bash
cd WT && /usr/bin/grep -rnE "getBrandShare[A-Za-z]*\((slug|publicShare\.slug|shareSlug|share\.slug)|postBrandShareReportQuery\(\s*slug|accessToken \?\? undefined\)" src --include='*.ts' --include='*.tsx' | /usr/bin/grep -v "getBrandShareInfo" || echo "no slug-based reader calls"
cd WT && /usr/bin/grep -rn "shareHeaders(" src | /usr/bin/grep -v "src/services/query.ts" || echo "shareHeaders only in query.ts"
```

Expected: `no slug-based reader calls` and `shareHeaders only in query.ts`. If zsh rejects `--include`, run the first grep once per file listed in **Files**.

- [ ] **Step 7: Type gate on the touched files, the suites, then commit**

```bash
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "services/query|labelling|creative-analysis|useCustomReports|useReportTemplates|CampaignContent|PaidMediaContent|SentimentAnalysis|SignalTrendsListContent|SignalDetailContent|share/brand|insightSurface|insightReaders"
cd WT && for f in src/services/insightReaders.test.ts src/services/insightSurface.test.ts src/context/PublicShareContext.test.tsx src/services/creative-analysis/hooks.test.ts src/components/brands/reports/ReportsContent.test.tsx src/hooks/useBrandReports.test.ts "src/app/share/dashboard/[slug]/page.test.tsx"; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected:
- the count is ≤ baseline;
- the second command prints only lines that the Task 0 per-file baseline lists;
- the new suites pass;
- the old suites match their Task 0 results.

```bash
cd WT && F=(src/services/query.ts src/services/insightReaders.test.ts src/services/labelling/api.ts src/services/labelling/hooks.ts src/services/creative-analysis/api.ts src/services/creative-analysis/hooks.ts src/hooks/useReportTemplates.ts src/components/brands/insight/PaidMediaContent.tsx src/components/brands/insight/SentimentAnalysis.tsx src/components/signal-trends/SignalTrendsListContent.tsx src/components/signal-detail/SignalDetailContent.tsx "src/app/share/brand/[slug]/page.tsx" "src/app/share/brand/[slug]/atl/page.tsx" "src/app/share/brand/[slug]/earned-media/page.tsx" "src/app/share/brand/[slug]/owned-media/page.tsx" "src/app/share/brand/[slug]/paid-media/page.tsx" "src/app/share/brand/[slug]/campaigns/page_old_jeff.tsx"); H=(src/hooks/useCustomReports.ts src/components/brands/CampaignContent.tsx); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" "${H[@]}" && /usr/bin/git add "${F[@]}" "${H[@]}" && /usr/bin/git commit -F - <<'EOF'
refactor(web): share insight readers take the surface's api, not slug + token

All 27 readers (query.ts, labelling, creative-analysis) now take an
InsightApi; shareInsightSurface(slug, token).api sends byte-identical
calls (insightReaders.test.ts pins every one) and share query keys keep
the bare slug. The portal will pass its BFF api to the same readers.
Spec 2026-10-07 §4.1.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 4: Page bodies move out of the share routes; hrefs come from `basePath`; the route resolver

**Files:**
- Create: `src/lib/insight-surface/tabs.ts` (inventory only; Task 5 adds the rules)
- Create: `src/lib/insight-surface/routes.ts`
- Test: `src/lib/insight-surface/routes.test.ts` (create)
- Move (with `git mv`) → `src/components/insight-surface/pages/`:

  | From `src/app/share/brand/[slug]/` | To `src/components/insight-surface/pages/` |
  |---|---|
  | `page.tsx` | `InsightOverviewPage.tsx` |
  | `campaigns/page.tsx` | `InsightCampaignsPage.tsx` |
  | `campaigns/[reportId]/page.tsx` | `InsightCampaignDetailPage.tsx` |
  | `business/page.tsx` | `InsightBusinessPage.tsx` |
  | `paid-media/page.tsx` | `InsightPaidMediaPage.tsx` |
  | `owned-media/page.tsx` | `InsightOwnedMediaPage.tsx` |
  | `earned-media/page.tsx` | `InsightEarnedMediaPage.tsx` |
  | `atl/page.tsx` | `InsightAtlPage.tsx` |
  | `signals/page.tsx` | `InsightSignalsPage.tsx` |
  | `signals/[signalId]/page.tsx` | `InsightSignalDetailPage.tsx` |
  | `social-listening/page.tsx` | `InsightListeningPage.tsx` |
  | `social-listening/[topicId]/page.tsx` | `InsightListeningTopicPage.tsx` |

- Create (at the 12 old paths): thin route wrappers
- Create: `src/components/insight-surface/InsightTabRouter.tsx`
- Modify: `src/components/brands/TrendsSignalSection.tsx`, `src/components/brands/OverviewHomeContent.tsx`, `src/components/signal-trends/SignalTrendsListContent.tsx`

**Interfaces:**
- Consumes: `usePublicShare()` with its `surface`; `insightHref` (Task 2).
- Produces:

```ts
// src/lib/insight-surface/tabs.ts
export const INSIGHT_SURFACE_TAB_KEYS: readonly ["overview","campaigns","business","paid-media","owned-media","earned-media","atl","signals","social-listening"];
export type SurfaceTabKey = (typeof INSIGHT_SURFACE_TAB_KEYS)[number];
export function isSurfaceTabKey(value: string): value is SurfaceTabKey;

// src/lib/insight-surface/routes.ts
export type InsightRoute =
  | { kind: "tab"; tab: SurfaceTabKey }
  | { kind: "campaign"; reportId: string }
  | { kind: "signal"; signalId: string }
  | { kind: "listening-topic"; topicId: string };
export function resolveInsightRoute(segments: readonly string[] | undefined): InsightRoute | null;

// src/components/insight-surface/InsightTabRouter.tsx
export function InsightTabRouter(props: { route: InsightRoute }): JSX.Element;
```

The page bodies:
- `InsightCampaignDetailPage({ reportId })`, `InsightSignalDetailPage({ signalId })` and `InsightListeningTopicPage({ topicId })` take their id as a prop.
- The other nine take no props.
- All twelve are default exports and read the brand and surface from `usePublicShare()`.
- They keep the `useRouter` calls they already had. They are moved code, never rendered in unit tests, so the Global Constraint on `next/navigation` does not apply to them.

- [ ] **Step 1: Write the failing resolver test**

Create `src/lib/insight-surface/routes.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { resolveInsightRoute } from "./routes";

// Named mutations (plan Task 4):
// - drop `head === "overview"` → "has no /overview page"
// - accept more than two segments → "refuses deeper paths"
// - drop `default: return null` (answer a tab for any id) → "refuses ids under a tab without detail pages"

describe("resolveInsightRoute (spec 2026-10-07 §4.2)", () => {
  it("is the overview at the surface root", () => {
    expect(resolveInsightRoute(undefined)).toEqual({
      kind: "tab",
      tab: "overview",
    });
    expect(resolveInsightRoute([])).toEqual({ kind: "tab", tab: "overview" });
  });

  it("names every tab page", () => {
    for (const tab of [
      "campaigns",
      "business",
      "paid-media",
      "owned-media",
      "earned-media",
      "atl",
      "signals",
      "social-listening",
    ]) {
      expect(resolveInsightRoute([tab])).toEqual({ kind: "tab", tab });
    }
  });

  it("names the three detail pages", () => {
    expect(resolveInsightRoute(["campaigns", "r1"])).toEqual({
      kind: "campaign",
      reportId: "r1",
    });
    expect(resolveInsightRoute(["signals", "42"])).toEqual({
      kind: "signal",
      signalId: "42",
    });
    expect(resolveInsightRoute(["social-listening", "t1"])).toEqual({
      kind: "listening-topic",
      topicId: "t1",
    });
  });

  it("has no /overview page", () => {
    expect(resolveInsightRoute(["overview"])).toBeNull();
  });

  it("refuses ids under a tab without detail pages", () => {
    expect(resolveInsightRoute(["paid-media", "x"])).toBeNull();
    expect(resolveInsightRoute(["business", "x"])).toBeNull();
  });

  it("refuses deeper paths and tabs a surface does not have", () => {
    expect(resolveInsightRoute(["campaigns", "r1", "edit"])).toBeNull();
    expect(resolveInsightRoute(["dashboard"])).toBeNull();
    expect(resolveInsightRoute(["nope"])).toBeNull();
  });
});
```

- [ ] **Step 2: Run it — FAIL**

Run: `cd WT && bun test src/lib/insight-surface/routes.test.ts`
Expected: `1 error`, `Cannot find module './routes'`.

- [ ] **Step 3: Implement the inventory and the resolver**

Create `src/lib/insight-surface/tabs.ts`:

```ts
/**
 * Tabs of the read-only insight surfaces (spec 2026-10-07 §4) — the public
 * share link, the client portal, the agency's client preview. Moved from
 * the share layout's `PUBLIC_SHARE_TAB_KEYS`; same order, same members
 * (no custom `dashboard` — it has no read-only page).
 */
import type { TabKey } from "@/constants/insightsTabs";

export const INSIGHT_SURFACE_TAB_KEYS = [
  "overview",
  "campaigns",
  "business",
  "paid-media",
  "owned-media",
  "earned-media",
  "atl",
  "signals",
  "social-listening",
] as const satisfies readonly TabKey[];

export type SurfaceTabKey = (typeof INSIGHT_SURFACE_TAB_KEYS)[number];

export function isSurfaceTabKey(value: string): value is SurfaceTabKey {
  return (INSIGHT_SURFACE_TAB_KEYS as readonly string[]).includes(value);
}
```

Create `src/lib/insight-surface/routes.ts`:

```ts
/**
 * Which page a read-only insight surface shows for the path under its
 * basePath (spec 2026-10-07 §4.2). The share link has one route file per
 * page; the portal and the preview have one optional catch-all
 * (`[[...tab]]`) and ask this. Pure.
 */
import { isSurfaceTabKey, type SurfaceTabKey } from "./tabs";

export type InsightRoute =
  | { kind: "tab"; tab: SurfaceTabKey }
  | { kind: "campaign"; reportId: string }
  | { kind: "signal"; signalId: string }
  | { kind: "listening-topic"; topicId: string };

export function resolveInsightRoute(
  segments: readonly string[] | undefined
): InsightRoute | null {
  const parts = segments ?? [];
  if (parts.length === 0) return { kind: "tab", tab: "overview" };
  if (parts.length > 2) return null;
  const [head, id] = parts;
  // The overview IS the root; there is no `/overview` page on any surface.
  if (!isSurfaceTabKey(head) || head === "overview") return null;
  if (id === undefined) return { kind: "tab", tab: head };
  if (!id) return null;
  switch (head) {
    case "campaigns":
      return { kind: "campaign", reportId: id };
    case "signals":
      return { kind: "signal", signalId: id };
    case "social-listening":
      return { kind: "listening-topic", topicId: id };
    default:
      return null;
  }
}
```

- [ ] **Step 4: Run — PASS, then the named mutations**

Run: `cd WT && bun test src/lib/insight-surface/routes.test.ts`
Expected: `6 pass`. Apply each of the three mutations: each fails its named test. Restore.

- [ ] **Step 5: Move the page bodies**

```bash
cd WT && S="src/app/share/brand/[slug]" && D=src/components/insight-surface/pages && mkdir -p "$D" && \
/usr/bin/git mv "$S/page.tsx" "$D/InsightOverviewPage.tsx" && \
/usr/bin/git mv "$S/campaigns/page.tsx" "$D/InsightCampaignsPage.tsx" && \
/usr/bin/git mv "$S/campaigns/[reportId]/page.tsx" "$D/InsightCampaignDetailPage.tsx" && \
/usr/bin/git mv "$S/business/page.tsx" "$D/InsightBusinessPage.tsx" && \
/usr/bin/git mv "$S/paid-media/page.tsx" "$D/InsightPaidMediaPage.tsx" && \
/usr/bin/git mv "$S/owned-media/page.tsx" "$D/InsightOwnedMediaPage.tsx" && \
/usr/bin/git mv "$S/earned-media/page.tsx" "$D/InsightEarnedMediaPage.tsx" && \
/usr/bin/git mv "$S/atl/page.tsx" "$D/InsightAtlPage.tsx" && \
/usr/bin/git mv "$S/signals/page.tsx" "$D/InsightSignalsPage.tsx" && \
/usr/bin/git mv "$S/signals/[signalId]/page.tsx" "$D/InsightSignalDetailPage.tsx" && \
/usr/bin/git mv "$S/social-listening/page.tsx" "$D/InsightListeningPage.tsx" && \
/usr/bin/git mv "$S/social-listening/[topicId]/page.tsx" "$D/InsightListeningTopicPage.tsx" && \
/usr/bin/git status --short | head -20
```

Expected: twelve `R` lines. `campaigns/page_old_jeff.tsx` and `layout.tsx` stay where they are.

- [ ] **Step 6: Rename the moved functions; give the detail bodies their ids; take hrefs from the surface**

Seven bodies only change their function name:

| File | Change |
|---|---|
| `InsightOverviewPage.tsx` | `export default function PublicShareOverviewPage()` → `export default function InsightOverviewPage()` |
| `InsightBusinessPage.tsx` | `PublicShareBusinessPage` → `InsightBusinessPage` |
| `InsightPaidMediaPage.tsx` | `PublicSharePaidMediaPage` → `InsightPaidMediaPage` |
| `InsightOwnedMediaPage.tsx` | `PublicShareOwnedMediaPage` → `InsightOwnedMediaPage` |
| `InsightEarnedMediaPage.tsx` | `PublicShareEarnedMediaPage` → `InsightEarnedMediaPage` |
| `InsightAtlPage.tsx` | `PublicShareATLPage` → `InsightAtlPage` |
| `InsightSignalsPage.tsx` | `PublicShareSignalsPage` → `InsightSignalsPage` |

The other five are replaced whole:

`InsightCampaignsPage.tsx`:

```tsx
"use client";

import { useRouter } from "next/navigation";
import { PlusIcon } from "@phosphor-icons/react";
import EmptyStateConnectData from "@/components/base/EmptyStateConnectData";
import ReportsContent from "@/components/brands/reports/ReportsContent";
import { useBrandReports } from "@/hooks/useBrandReports";
import { usePublicShare } from "@/context/PublicShareContext";
import { insightHref } from "@/services/insightSurface";

/** Campaigns on a read-only insight surface (share link, portal, preview). */
export default function InsightCampaignsPage() {
  const ctx = usePublicShare();
  const router = useRouter();
  const brandId = ctx?.brandId ?? "";
  const brandName = ctx?.brandName ?? "this brand";

  const { data } = useBrandReports(brandId);

  if (!ctx) return null;

  if (!data) {
    return (
      <EmptyStateConnectData
        tabKey="campaigns"
        showConnectButton={false}
        connectButtonText="Create New Campaign"
        connectButtonIcon={<PlusIcon size={16} weight="regular" />}
        showDemoButton={false}
        isLoading={false}
      />
    );
  }

  return (
    <ReportsContent
      data={data}
      brandId={brandId}
      brandName={brandName}
      onSelectReport={(id) =>
        router.push(insightHref(ctx.surface, `campaigns/${id}`))
      }
    />
  );
}
```

`InsightCampaignDetailPage.tsx`:

```tsx
"use client";

import ReportView from "@/components/brands/reports/ReportView";
import { usePublicShare } from "@/context/PublicShareContext";

/** One campaign report on a read-only insight surface. */
export default function InsightCampaignDetailPage({
  reportId,
}: {
  reportId: string;
}) {
  const ctx = usePublicShare();
  const brandId = ctx?.brandId;
  if (!brandId) return null;
  return <ReportView brandId={brandId} reportId={reportId} />;
}
```

`InsightSignalDetailPage.tsx`:

```tsx
"use client";

import SignalDetailContent from "@/components/signal-detail/SignalDetailContent";
import { usePublicShare } from "@/context/PublicShareContext";

/** One trend signal on a read-only insight surface. */
export default function InsightSignalDetailPage({
  signalId,
}: {
  signalId: string;
}) {
  const ctx = usePublicShare();
  const brandId = ctx?.brandId;
  if (!brandId) return null;
  return <SignalDetailContent brandId={brandId} signalId={signalId} />;
}
```

`InsightListeningPage.tsx`: keep the file's doc comment, but replace "the share tree" with "the surface's tree". Replace the code with:

```tsx
"use client";

import EmptyStateConnectData from "@/components/base/EmptyStateConnectData";
import TopicIndex from "@/components/brands/social-listening/TopicIndex";
import { useSocialListening } from "@/hooks/useSocialListening";
import { usePublicShare } from "@/context/PublicShareContext";
import { insightHref } from "@/services/insightSurface";

export default function InsightListeningPage() {
  const ctx = usePublicShare();
  const brandId = ctx?.brandId ?? "";
  const { fixture, isDemoOn, brandKey, topics } = useSocialListening(brandId);

  if (!ctx) return null;

  if (!isDemoOn || !fixture || !brandKey) {
    return (
      <EmptyStateConnectData
        tabKey="social-listening"
        showConnectButton={false}
        isLoading={false}
      />
    );
  }

  return (
    <TopicIndex
      brandId={brandId}
      brandKey={brandKey}
      topics={topics}
      onCreate={() => {}}
      basePath={insightHref(ctx.surface, "social-listening")}
      readOnly
    />
  );
}
```

`InsightListeningTopicPage.tsx`: keep the doc comment, but replace "a share `basePath`" with "the surface's `basePath`". Replace the code with:

```tsx
"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import EmptyStateConnectData from "@/components/base/EmptyStateConnectData";
import TopicDashboard from "@/components/brands/social-listening/TopicDashboard";
import { useSocialListening } from "@/hooks/useSocialListening";
import { usePublicShare } from "@/context/PublicShareContext";
import { insightHref } from "@/services/insightSurface";

export default function InsightListeningTopicPage({
  topicId,
}: {
  topicId: string;
}) {
  const ctx = usePublicShare();
  const router = useRouter();
  const brandId = ctx?.brandId ?? "";

  const { isDemoOn, brandKey, topics, detailFor } = useSocialListening(brandId);
  const topic = topics.find((t) => t.id === topicId) ?? null;
  const detail = topic ? detailFor(topicId) : null;

  const basePath = ctx ? insightHref(ctx.surface, "social-listening") : "";

  // Unknown topic on a demo brand → bounce back to the topic index.
  useEffect(() => {
    if (ctx && isDemoOn && (!topic || !detail)) {
      router.replace(basePath);
    }
  }, [ctx, isDemoOn, topic, detail, basePath, router]);

  if (!ctx) return null;

  if (!isDemoOn || !brandKey) {
    return (
      <EmptyStateConnectData
        tabKey="social-listening"
        showConnectButton={false}
        isLoading={false}
      />
    );
  }

  if (!topic || !detail) {
    // Redirect is in-flight (effect above) — render nothing this frame.
    return null;
  }

  return (
    <TopicDashboard
      brandId={brandId}
      brandKey={brandKey}
      topic={topic}
      detail={detail}
      allTopics={topics}
      basePath={basePath}
      readOnly
    />
  );
}
```

- [ ] **Step 7: The share route files become wrappers**

Nine static pages each get a one-line re-export. Create:
- `src/app/share/brand/[slug]/page.tsx`;
- `campaigns/page.tsx`, `business/page.tsx`, `paid-media/page.tsx`, `owned-media/page.tsx`;
- `earned-media/page.tsx`, `atl/page.tsx`, `signals/page.tsx`, `social-listening/page.tsx`.

`src/app/share/brand/[slug]/page.tsx`:

```tsx
// The public share Overview — the body is shared with the client portal
// and the client preview (spec 2026-10-07 §4.1).
export { default } from "@/components/insight-surface/pages/InsightOverviewPage";
```

and the same line with each body's name for the other eight:
- `InsightCampaignsPage`;
- `InsightBusinessPage`, `InsightPaidMediaPage`, `InsightOwnedMediaPage`;
- `InsightEarnedMediaPage`, `InsightAtlPage`;
- `InsightSignalsPage`, `InsightListeningPage`.

Each comment names its tab.

The three detail pages read their id from `params` (a `Promise` in Next 16):

`src/app/share/brand/[slug]/campaigns/[reportId]/page.tsx`:

```tsx
import InsightCampaignDetailPage from "@/components/insight-surface/pages/InsightCampaignDetailPage";

export default async function PublicShareCampaignDetailPage({
  params,
}: {
  params: Promise<{ slug: string; reportId: string }>;
}) {
  const { reportId } = await params;
  return <InsightCampaignDetailPage reportId={reportId} />;
}
```

`src/app/share/brand/[slug]/signals/[signalId]/page.tsx`:

```tsx
import InsightSignalDetailPage from "@/components/insight-surface/pages/InsightSignalDetailPage";

export default async function PublicShareSignalDetailPage({
  params,
}: {
  params: Promise<{ slug: string; signalId: string }>;
}) {
  const { signalId } = await params;
  return <InsightSignalDetailPage signalId={signalId} />;
}
```

`src/app/share/brand/[slug]/social-listening/[topicId]/page.tsx`:

```tsx
import InsightListeningTopicPage from "@/components/insight-surface/pages/InsightListeningTopicPage";

export default async function PublicShareSocialListeningTopicPage({
  params,
}: {
  params: Promise<{ slug: string; topicId: string }>;
}) {
  const { topicId } = await params;
  return <InsightListeningTopicPage topicId={topicId} />;
}
```

- [ ] **Step 8: One router for the catch-all surfaces**

Create `src/components/insight-surface/InsightTabRouter.tsx`:

```tsx
"use client";

import type { InsightRoute } from "@/lib/insight-surface/routes";

import InsightAtlPage from "./pages/InsightAtlPage";
import InsightBusinessPage from "./pages/InsightBusinessPage";
import InsightCampaignDetailPage from "./pages/InsightCampaignDetailPage";
import InsightCampaignsPage from "./pages/InsightCampaignsPage";
import InsightEarnedMediaPage from "./pages/InsightEarnedMediaPage";
import InsightListeningPage from "./pages/InsightListeningPage";
import InsightListeningTopicPage from "./pages/InsightListeningTopicPage";
import InsightOverviewPage from "./pages/InsightOverviewPage";
import InsightOwnedMediaPage from "./pages/InsightOwnedMediaPage";
import InsightPaidMediaPage from "./pages/InsightPaidMediaPage";
import InsightSignalDetailPage from "./pages/InsightSignalDetailPage";
import InsightSignalsPage from "./pages/InsightSignalsPage";

/**
 * The page body for a resolved route — what `/share/brand/[slug]/**` does
 * with one file per page, for the surfaces that have one optional
 * catch-all (the client portal, the client preview). Spec 2026-10-07 §4.2.
 */
export function InsightTabRouter({ route }: { route: InsightRoute }) {
  switch (route.kind) {
    case "campaign":
      return <InsightCampaignDetailPage reportId={route.reportId} />;
    case "signal":
      return <InsightSignalDetailPage signalId={route.signalId} />;
    case "listening-topic":
      return <InsightListeningTopicPage topicId={route.topicId} />;
    case "tab":
      switch (route.tab) {
        case "overview":
          return <InsightOverviewPage />;
        case "campaigns":
          return <InsightCampaignsPage />;
        case "business":
          return <InsightBusinessPage />;
        case "paid-media":
          return <InsightPaidMediaPage />;
        case "owned-media":
          return <InsightOwnedMediaPage />;
        case "earned-media":
          return <InsightEarnedMediaPage />;
        case "atl":
          return <InsightAtlPage />;
        case "signals":
          return <InsightSignalsPage />;
        case "social-listening":
          return <InsightListeningPage />;
      }
  }
}
```

If tsc reports "not all code paths return a value", add `return null;` after the outer `switch`.

- [ ] **Step 9: The three remaining hardcoded share hrefs**

`src/components/brands/TrendsSignalSection.tsx`:
- Replace the `shareSlug` prop doc and declaration with

```tsx
  /**
   * Saat diisi, navigasi diarahkan ke `{shareBasePath}/signals/...` —
   * basePath surface read-only (public share, portal klien, preview klien).
   * Saat undefined, navigasi default ke `/brands/{brandId}/insight/signals/...`.
   */
  shareBasePath?: string;
```

- In the destructure, replace `shareSlug,` with `shareBasePath,`.
- Replace

```tsx
  const signalsBasePath = shareSlug
    ? `/share/brand/${shareSlug}/signals`
    : `/brands/${brandId}/insight/signals`;
```

  with

```tsx
  const signalsBasePath = shareBasePath
    ? `${shareBasePath}/signals`
    : `/brands/${brandId}/insight/signals`;
```

`src/components/brands/OverviewHomeContent.tsx`: replace

```tsx
            shareSlug={
              isPublicView ? (publicCtx?.slug ?? undefined) : undefined
            }
```

with

```tsx
            shareBasePath={
              isPublicView ? (publicCtx?.surface.basePath ?? undefined) : undefined
            }
```

`src/components/signal-trends/SignalTrendsListContent.tsx`:
- Add `import { insightHref } from "@/services/insightSurface";` beside the `@/services/query` import.
- Delete the line `const slug = publicCtx?.slug ?? "";` that Task 3 left.
- Replace

```tsx
  const signalDetailHref = (signalId: number | string) =>
    isPublicView
      ? `/share/brand/${slug}/signals/${signalId}`
      : `/brands/${brandId}/insight/signals/${signalId}`;
```

  with

```tsx
  const signalDetailHref = (signalId: number | string) =>
    isPublicView && shareSurface
      ? insightHref(shareSurface, `signals/${signalId}`)
      : `/brands/${brandId}/insight/signals/${signalId}`;
```

- [ ] **Step 10: No hardcoded share href is left in components, hooks or pages**

```bash
cd WT && /usr/bin/grep -rn '/share/brand/\${' src/components src/hooks "src/app/share/brand" || echo "no hardcoded share hrefs"
```

Expected: only the share layout's `const basePath = \`/share/brand/${slug}\`;`, which Task 5 deletes. Nothing under `src/components` or `src/hooks`.

- [ ] **Step 11: Types, suites, the build (route files changed shape), commit**

```bash
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "insight-surface|share/brand|TrendsSignalSection|OverviewHomeContent|SignalTrendsListContent"
cd WT && for f in src/lib/insight-surface/routes.test.ts src/services/insightReaders.test.ts src/components/brands/insight/DailySummaryOverview.test.tsx src/hooks/useSocialListening.test.ts; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
cd WT && node ./node_modules/next/dist/bin/next build 2>&1 | /usr/bin/grep -E "share/brand|Failed to compile|Module not found|Error:" | head -30
```

Expected:
- the count is ≤ baseline, with no new lines for the touched files;
- every suite is green;
- the build lists the twelve `/share/brand/[slug]…` routes and no compile error.

If Next rejects `export { default } from` in a page file, write each wrapper as `import X from "…"; export default X;` instead.

```bash
cd WT && F=(src/lib/insight-surface/tabs.ts src/lib/insight-surface/routes.ts src/lib/insight-surface/routes.test.ts src/components/insight-surface/InsightTabRouter.tsx src/components/insight-surface/pages/*.tsx src/components/brands/TrendsSignalSection.tsx src/components/brands/OverviewHomeContent.tsx src/components/signal-trends/SignalTrendsListContent.tsx "src/app/share/brand/[slug]/page.tsx" "src/app/share/brand/[slug]/campaigns/page.tsx" "src/app/share/brand/[slug]/campaigns/[reportId]/page.tsx" "src/app/share/brand/[slug]/business/page.tsx" "src/app/share/brand/[slug]/paid-media/page.tsx" "src/app/share/brand/[slug]/owned-media/page.tsx" "src/app/share/brand/[slug]/earned-media/page.tsx" "src/app/share/brand/[slug]/atl/page.tsx" "src/app/share/brand/[slug]/signals/page.tsx" "src/app/share/brand/[slug]/signals/[signalId]/page.tsx" "src/app/share/brand/[slug]/social-listening/page.tsx" "src/app/share/brand/[slug]/social-listening/[topicId]/page.tsx"); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add -A src/components/insight-surface "src/app/share/brand/[slug]" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
refactor(web): share page bodies move to insight-surface; hrefs follow basePath

The twelve /share/brand/[slug] pages become thin wrappers over bodies in
components/insight-surface/pages, which take their ids as props, so the
portal and the client preview can render them from one [[...tab]] route
(resolveInsightRoute + InsightTabRouter). Campaign, signal and listening
links come from the surface's basePath instead of /share/brand/{slug}.
Spec 2026-10-07 §4.1–4.2.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 5: Tab rules and `InsightSurfaceLayout` (the share layout uses it)

**Files:**
- Modify: `src/lib/insight-surface/tabs.ts`, `src/lib/insight-surface/routes.ts`
- Test: `src/lib/insight-surface/tabs.test.ts` (create)
- Create: `src/components/insight-surface/InsightSurfaceLayout.tsx`
- Create: `src/components/insight-surface/ShareInsightFrame.tsx`
- Test: `src/components/insight-surface/InsightSurfaceLayout.test.tsx` (create)
- Modify: `src/app/share/brand/[slug]/layout.tsx` (replaced whole)

**Interfaces:**
- Consumes: `INSIGHT_SURFACE_TAB_KEYS`, `isSurfaceTabKey`, `resolveInsightRoute` (Task 4); `usePublicShare()` with its `surface`, `insightHref` (Task 2); `GLOBAL_INSIGHTS_TABS_BY_KEY` (`@/constants/insightsTabs`); `InsightPageHeaderRow` (`@/components/brands/insight/InsightPageHeader`); `BrandInsightTabs` and its type `BrandInsightTabItem`; v1 `TabsRounded` (`@/components/frndos/TabsRounded`, `scrollOnMobile`).
- Produces:

```ts
// src/lib/insight-surface/tabs.ts (added)
export type ResolvedTabMap = Partial<Record<TabKey, { label: string; is_visible: boolean }>>;
export interface SurfaceTab { id: SurfaceTabKey; name: string; path: string } // path "" | "/paid-media" …
export function surfaceTabs(resolved: ResolvedTabMap | undefined, audience: InsightAudience): SurfaceTab[];
export function relativeSurfacePath(pathname: string, basePath: string): string;
export function matchSurfaceTab(tabs: readonly SurfaceTab[], relativePath: string): SurfaceTab | undefined;
export function isSignalDetailPath(relativePath: string): boolean;
export function isClientEligibleTab(id: string): boolean;

// src/lib/insight-surface/routes.ts (added)
export function surfaceRedirect(tabs: readonly SurfaceTab[], relativePath: string): string | null;

// src/components/insight-surface/InsightSurfaceLayout.tsx
export interface InsightFrameProps { tabs: BrandInsightTabItem[]; children: ReactNode }
export function InlineInsightFrame(props: InsightFrameProps): JSX.Element;
export interface InsightSurfaceLayoutProps {
  resolved: ResolvedTabMap | undefined;
  pathname: string;
  onNavigate: (href: string) => void;
  onReplace: (href: string) => void;
  onActiveTabChange?: (tab: SurfaceTabKey) => void;
  frame?: ComponentType<InsightFrameProps>; // default InlineInsightFrame
  children: ReactNode;
}
export function InsightSurfaceLayout(props: InsightSurfaceLayoutProps): JSX.Element | null;

// src/components/insight-surface/ShareInsightFrame.tsx
export function ShareInsightFrame(props: InsightFrameProps): JSX.Element;
```

The rule that matters most, and differs per audience: on `"public"` a tab missing from the resolved map is visible, exactly as the share layout always did. On `"client"` and `"preview"` a tab is visible ONLY when its row says `is_visible: true`. A missing map means no tabs (Review Focus 1).

- [ ] **Step 1: Write the failing rules test**

Create `src/lib/insight-surface/tabs.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { surfaceRedirect } from "./routes";
import {
  isClientEligibleTab,
  isSignalDetailPath,
  matchSurfaceTab,
  relativeSurfacePath,
  surfaceTabs,
} from "./tabs";

// Named mutations (plan Task 5):
// - make `strict` always false → "treats a missing map as no tabs for clients"
// - drop the `tab.path !== ""` guard in matchSurfaceTab → "does not let the overview swallow every path"
// - drop the resolveInsightRoute check in surfaceRedirect → "moves a path no page answers"
// - default a client row's visibility to `row?.is_visible ?? true` → "hides a client tab its row does not open"

describe("surfaceTabs (spec 2026-10-07 §4.1, I-2)", () => {
  it("keeps the public share's nine tabs, order and labels", () => {
    expect(surfaceTabs(undefined, "public")).toEqual([
      { id: "overview", name: "Overview", path: "" },
      { id: "campaigns", name: "Campaigns", path: "/campaigns" },
      { id: "business", name: "Business", path: "/business" },
      { id: "paid-media", name: "Ads", path: "/paid-media" },
      { id: "owned-media", name: "Social Media", path: "/owned-media" },
      { id: "earned-media", name: "Influencers", path: "/earned-media" },
      { id: "atl", name: "ATL", path: "/atl" },
      { id: "signals", name: "Trends", path: "/signals" },
      { id: "social-listening", name: "Listening", path: "/social-listening" },
    ]);
  });

  it("applies the public link's overrides", () => {
    const tabs = surfaceTabs(
      {
        "paid-media": { label: "Paid", is_visible: true },
        atl: { label: "ATL", is_visible: false },
      },
      "public"
    );
    expect(tabs.map((t) => t.name)).toContain("Paid");
    expect(tabs.map((t) => t.id)).not.toContain("atl");
    expect(tabs).toHaveLength(8);
  });

  it("treats a missing map as no tabs for clients", () => {
    expect(surfaceTabs(undefined, "client")).toEqual([]);
    expect(surfaceTabs({}, "preview")).toEqual([]);
  });

  it("hides a client tab its row does not open", () => {
    const tabs = surfaceTabs(
      {
        overview: { label: "Overview", is_visible: false },
        business: { label: "Business", is_visible: true },
        signals: { label: "Trends", is_visible: true },
      },
      "client"
    );
    expect(tabs).toEqual([
      { id: "business", name: "Business", path: "/business" },
      { id: "signals", name: "Trends", path: "/signals" },
    ]);
  });
});

describe("matching and redirects", () => {
  const tabs = surfaceTabs(
    {
      overview: { label: "Overview", is_visible: true },
      campaigns: { label: "Campaigns", is_visible: true },
    },
    "client"
  );

  it("reads the path under the surface", () => {
    expect(
      relativeSurfacePath("/s/fcn/frndglow/insights/campaigns", "/s/fcn/frndglow/insights")
    ).toBe("/campaigns");
    expect(
      relativeSurfacePath("/s/fcn/frndglow/insights", "/s/fcn/frndglow/insights")
    ).toBe("");
  });

  it("matches a tab and its detail pages", () => {
    expect(matchSurfaceTab(tabs, "")?.id).toBe("overview");
    expect(matchSurfaceTab(tabs, "/campaigns")?.id).toBe("campaigns");
    expect(matchSurfaceTab(tabs, "/campaigns/r1")?.id).toBe("campaigns");
  });

  it("does not let the overview swallow every path", () => {
    expect(matchSurfaceTab(tabs, "/paid-media")).toBeUndefined();
    expect(matchSurfaceTab(tabs, "/campaignsx")).toBeUndefined();
  });

  it("stays on an open page", () => {
    expect(surfaceRedirect(tabs, "")).toBeNull();
    expect(surfaceRedirect(tabs, "/campaigns/r1")).toBeNull();
  });

  it("moves a hidden tab to the first open one", () => {
    expect(surfaceRedirect(tabs, "/paid-media")).toBe("");
    const noOverview = surfaceTabs(
      { atl: { label: "ATL", is_visible: true } },
      "client"
    );
    expect(surfaceRedirect(noOverview, "")).toBe("/atl");
  });

  it("moves a path no page answers", () => {
    expect(surfaceRedirect(tabs, "/campaigns/r1/edit")).toBe("");
  });

  it("leaves the decision to the caller when nothing is open", () => {
    expect(surfaceRedirect([], "/campaigns")).toBeNull();
  });

  it("knows the signal detail page and the client-eligible tabs", () => {
    expect(isSignalDetailPath("/signals/42")).toBe(true);
    expect(isSignalDetailPath("/signals")).toBe(false);
    expect(isClientEligibleTab("social-listening")).toBe(true);
    expect(isClientEligibleTab("dashboard")).toBe(false);
  });
});
```

- [ ] **Step 2: Run it — FAIL**

Run: `cd WT && bun test src/lib/insight-surface/tabs.test.ts`
Expected: an import failure (`surfaceTabs` / `surfaceRedirect` are not exported).

- [ ] **Step 3: Implement the rules**

Append to `src/lib/insight-surface/tabs.ts`. Add its imports to the file's existing import block, so the type import of `TabKey` merges:

```ts
import { GLOBAL_INSIGHTS_TABS_BY_KEY } from "@/constants/insightsTabs";

import type { InsightAudience } from "./types";

/** `insights_tab_settings.resolved` — fully resolved by the api. */
export type ResolvedTabMap = Partial<
  Record<TabKey, { label: string; is_visible: boolean }>
>;

export interface SurfaceTab {
  id: SurfaceTabKey;
  name: string;
  /** Under the surface's basePath: "" for the overview, "/paid-media" … */
  path: string;
}

/**
 * The tabs a surface shows, in strip order. The public link keeps its old
 * rule — a tab missing from the map is visible (`resolvedMapToTabs`). A
 * client (and the agency previewing as one) sees a tab ONLY when its row
 * opens it: the agency ticks Clients per tab, default off (spec I-2), so a
 * missing map or row must never open everything.
 */
export function surfaceTabs(
  resolved: ResolvedTabMap | undefined,
  audience: InsightAudience
): SurfaceTab[] {
  const strict = audience !== "public";
  return INSIGHT_SURFACE_TAB_KEYS.flatMap((id) => {
    const tab = GLOBAL_INSIGHTS_TABS_BY_KEY[id];
    const row = resolved?.[id];
    const visible = strict
      ? row?.is_visible === true
      : (row?.is_visible ?? true);
    if (!visible) return [];
    return [
      {
        id,
        name: row?.label ?? tab.label,
        path: id === "overview" ? "" : `/${tab.href}`,
      },
    ];
  });
}

export function relativeSurfacePath(
  pathname: string,
  basePath: string
): string {
  return pathname.replace(basePath, "");
}

/** A tab's own page, or one of its detail pages (`/campaigns/r1`). */
export function matchSurfaceTab(
  tabs: readonly SurfaceTab[],
  relativePath: string
): SurfaceTab | undefined {
  return tabs.find(
    (tab) =>
      tab.path === relativePath ||
      (tab.path !== "" && relativePath.startsWith(`${tab.path}/`))
  );
}

/** The signal detail page carries its own "Return" row, so no title row. */
export function isSignalDetailPath(relativePath: string): boolean {
  return /^\/signals\/[^/]+/.test(relativePath);
}

/** Tabs that can be opened for clients — every surface tab, never `dashboard`. */
export function isClientEligibleTab(id: string): boolean {
  return isSurfaceTabKey(id);
}
```

In `src/lib/insight-surface/routes.ts`:
- change `import { isSurfaceTabKey, type SurfaceTabKey } from "./tabs";` to

```ts
import {
  isSurfaceTabKey,
  matchSurfaceTab,
  type SurfaceTab,
  type SurfaceTabKey,
} from "./tabs";
```

- and append:

```ts
/**
 * Where a viewer goes when the path is not an open tab's page — a hidden
 * tab, a stale deep link, a path no page answers: the first open tab's
 * relative path ("" = the overview). Null = stay; also null when nothing
 * is open, which the caller decides about (the portal goes back to
 * Approvals).
 */
export function surfaceRedirect(
  tabs: readonly SurfaceTab[],
  relativePath: string
): string | null {
  if (tabs.length === 0) return null;
  const segments = relativePath.split("/").filter(Boolean);
  const onPage =
    matchSurfaceTab(tabs, relativePath) !== undefined &&
    resolveInsightRoute(segments) !== null;
  return onPage ? null : tabs[0].path;
}
```

`tabs.ts` imports nothing from `routes.ts`, so there is no cycle.

- [ ] **Step 4: Run — PASS, then the named mutations**

Run: `cd WT && bun test src/lib/insight-surface/tabs.test.ts && bun test src/lib/insight-surface/routes.test.ts`
Expected: both green. Apply the four mutations; each fails its named test. Restore.

- [ ] **Step 5: Write the failing layout test**

Create `src/components/insight-surface/InsightSurfaceLayout.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { cleanup, render, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { PublicShareProvider } from "@/context/PublicShareContext";
import type { ResolvedTabMap } from "@/lib/insight-surface/tabs";
import { portalInsightSurface } from "@/services/insightSurface";

import { InsightSurfaceLayout } from "./InsightSurfaceLayout";

// Named mutations (plan Task 5):
// - pass `"public"` instead of the surface's audience to surfaceTabs → "shows only the tabs open to clients"
// - drop the redirect effect → "redirects a hidden tab to the first open one"
// - drop `!isSignalDetailPath(...)` → "keeps the signal detail without the title row"

const body = () => within(document.body);
const BASE = "/s/fcn/frndglow/insights";
const OPEN: ResolvedTabMap = {
  overview: { label: "Overview", is_visible: true },
  business: { label: "Business", is_visible: false },
  "paid-media": { label: "Ads", is_visible: true },
  signals: { label: "Trends", is_visible: true },
};

function renderLayout(
  pathname: string,
  resolved: ResolvedTabMap | undefined = OPEN
) {
  const onNavigate = vi.fn();
  const onReplace = vi.fn();
  const onActiveTabChange = vi.fn();
  render(
    <PublicShareProvider
      slug="frndglow"
      brandId="01brand"
      brandName="frndGlow"
      brandLogo={null}
      accessToken={null}
      surface={portalInsightSurface("fcn", "frndglow")}
    >
      <InsightSurfaceLayout
        resolved={resolved}
        pathname={pathname}
        onNavigate={onNavigate}
        onReplace={onReplace}
        onActiveTabChange={onActiveTabChange}
      >
        <p>tab content</p>
      </InsightSurfaceLayout>
    </PublicShareProvider>
  );
  return { onNavigate, onReplace, onActiveTabChange };
}

describe("InsightSurfaceLayout (spec 2026-10-07 §4.1–4.2)", () => {
  beforeEach(() => vi.restoreAllMocks());
  afterEach(() => cleanup());

  it("shows only the tabs open to clients, titled and navigable", async () => {
    const user = userEvent.setup();
    const { onNavigate, onReplace, onActiveTabChange } = renderLayout(
      `${BASE}/paid-media`
    );
    for (const name of ["Overview", "Ads", "Trends"]) {
      expect(body().getByRole("button", { name })).toBeInTheDocument();
    }
    expect(body().queryByRole("button", { name: "Business" })).toBeNull();
    expect(
      body().getByRole("heading", { level: 1, name: "Ads" })
    ).toBeInTheDocument();
    expect(body().getByText("tab content")).toBeInTheDocument();
    expect(onReplace).not.toHaveBeenCalled();
    expect(onActiveTabChange).toHaveBeenCalledWith("paid-media");

    await user.click(body().getByRole("button", { name: "Overview" }));
    expect(onNavigate).toHaveBeenCalledWith(BASE);
  });

  it("redirects a hidden tab to the first open one", () => {
    const { onReplace } = renderLayout(`${BASE}/business`);
    expect(onReplace).toHaveBeenCalledWith(BASE);
  });

  it("redirects a path no page answers", () => {
    const { onReplace } = renderLayout(`${BASE}/paid-media/x`);
    expect(onReplace).toHaveBeenCalledWith(BASE);
  });

  it("keeps the signal detail without the title row", () => {
    const { onReplace } = renderLayout(`${BASE}/signals/42`);
    expect(body().queryByRole("heading", { level: 1 })).toBeNull();
    expect(body().getByText("tab content")).toBeInTheDocument();
    expect(onReplace).not.toHaveBeenCalled();
  });

  it("renders nothing for a client with no open tab", () => {
    const { onReplace } = renderLayout(BASE, undefined);
    expect(body().queryByRole("button")).toBeNull();
    expect(body().queryByText("tab content")).toBeNull();
    expect(onReplace).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 6: Run it — FAIL**

Run: `cd WT && bun test src/components/insight-surface/InsightSurfaceLayout.test.tsx`
Expected: `Cannot find module './InsightSurfaceLayout'`.

- [ ] **Step 7: Implement the layout and the share frame**

Create `src/components/insight-surface/InsightSurfaceLayout.tsx`:

```tsx
"use client";

import { useEffect, useMemo, type ComponentType, type ReactNode } from "react";

import type { BrandInsightTabItem } from "@/components/brands/insight/BrandInsightTabs";
import { InsightPageHeaderRow } from "@/components/brands/insight/InsightPageHeader";
import TabsRounded from "@/components/frndos/TabsRounded";
import { usePublicShare } from "@/context/PublicShareContext";
import { surfaceRedirect } from "@/lib/insight-surface/routes";
import {
  isSignalDetailPath,
  matchSurfaceTab,
  relativeSurfacePath,
  surfaceTabs,
  type ResolvedTabMap,
  type SurfaceTabKey,
} from "@/lib/insight-surface/tabs";
import { insightHref } from "@/services/insightSurface";

export interface InsightFrameProps {
  tabs: BrandInsightTabItem[];
  children: ReactNode;
}

/**
 * The client portal's and the client preview's frame: the tab strip above
 * the page, inside whatever shell the route draws. `scrollOnMobile` lets
 * nine tabs scroll sideways on a phone instead of widening the page.
 */
export function InlineInsightFrame({ tabs, children }: InsightFrameProps) {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <nav aria-label="Insights tabs" className="flex min-w-0 justify-center">
        <TabsRounded
          size="small"
          scrollOnMobile
          tabs={tabs.map((tab) => ({
            id: tab.id,
            label: tab.label,
            active: tab.active,
            onClick: tab.onClick,
          }))}
        />
      </nav>
      <div className="min-w-0">{children}</div>
    </div>
  );
}

export interface InsightSurfaceLayoutProps {
  /** `insights_tab_settings.resolved` of the share info / portal insight-info. */
  resolved: ResolvedTabMap | undefined;
  pathname: string;
  onNavigate: (href: string) => void;
  onReplace: (href: string) => void;
  /** The tab the path lands on, each time it changes (analytics). */
  onActiveTabChange?: (tab: SurfaceTabKey) => void;
  /** Default: the inline strip. The share link passes its floating chrome. */
  frame?: ComponentType<InsightFrameProps>;
  children: ReactNode;
}

/**
 * One layout for every read-only insight surface (spec 2026-10-07 §4.1):
 * the tab list (all tabs the share link shows; for a client, only those
 * ticked under Clients), the redirect away from a hidden or unknown path,
 * and the page's title row — whose slots the tabs portal their filters and
 * date range into. Navigation is by props so it renders without a router.
 */
export function InsightSurfaceLayout({
  resolved,
  pathname,
  onNavigate,
  onReplace,
  onActiveTabChange,
  frame: Frame = InlineInsightFrame,
  children,
}: InsightSurfaceLayoutProps) {
  const share = usePublicShare();
  const surface = share?.surface ?? null;
  const audience = surface?.audience ?? "public";
  const basePath = surface?.basePath ?? "";

  const tabs = useMemo(
    () => surfaceTabs(resolved, audience),
    [resolved, audience]
  );
  const relativePath = relativeSurfacePath(pathname, basePath);
  const active = matchSurfaceTab(tabs, relativePath);
  const target = surfaceRedirect(tabs, relativePath);
  const activeId = active?.id ?? null;

  // A deep link to a hidden tab, or a path no page answers, lands on the
  // first open tab (FR-25 on the share link; spec I-2 for clients).
  useEffect(() => {
    if (target !== null && surface) onReplace(insightHref(surface, target));
    // eslint-disable-next-line react-hooks/exhaustive-deps -- fire per target, not per callback identity
  }, [target, basePath]);

  useEffect(() => {
    if (activeId) onActiveTabChange?.(activeId);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- once per tab change
  }, [activeId]);

  if (!surface) return null;
  // A client with nothing open sees nothing; the route decides where to go.
  if (tabs.length === 0 && audience !== "public") return null;

  const activeTabId = activeId ?? tabs[0]?.id ?? "overview";
  const items: BrandInsightTabItem[] = tabs.map((tab) => ({
    id: tab.id,
    label: tab.name,
    active: tab.id === activeTabId,
    onClick: () => onNavigate(insightHref(surface, tab.path)),
  }));

  // Titled from the tab the path actually matches, not the fallback: an
  // unknown path would otherwise flash the wrong heading before the
  // redirect lands. The signal detail page has its own "Return" row.
  const title = active?.name ?? null;
  const showTitle = title !== null && !isSignalDetailPath(relativePath);

  return (
    <Frame tabs={items}>
      {showTitle ? <InsightPageHeaderRow title={title} /> : null}
      {children}
    </Frame>
  );
}
```

Create `src/components/insight-surface/ShareInsightFrame.tsx` (the share layout's chrome, moved verbatim; Task 13 swaps its grounds to `bg-app`):

```tsx
"use client";

import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";

import BrandInsightTabs from "@/components/brands/insight/BrandInsightTabs";
import {
  DashboardFloatingChrome,
  ScrollViewportEdgeFade,
} from "@/components/frndos";

import type { InsightFrameProps } from "./InsightSurfaceLayout";

/**
 * The public share link's frame: the floating top chrome (brand pill) with
 * the tabs portalled into its `#top-nav-tabs-slot` — the same pattern as
 * the private BrandInsightLayoutWrapper — over a scrolling content column.
 */
export function ShareInsightFrame({ tabs, children }: InsightFrameProps) {
  const [scrollRoot, setScrollRoot] = useState<HTMLDivElement | null>(null);
  const [tabsSlot, setTabsSlot] = useState<HTMLElement | null>(null);
  const bindScrollRoot = useCallback((el: HTMLDivElement | null) => {
    setScrollRoot(el);
  }, []);

  // Resolve the chrome's tabs slot once the chrome has mounted.
  useEffect(() => {
    let cancelled = false;
    let frame = 0;
    let attempts = 0;
    const maxAttempts = 90;
    const tick = () => {
      if (cancelled) return;
      attempts += 1;
      const el = document.getElementById(
        "top-nav-tabs-slot"
      ) as HTMLElement | null;
      if (el && el !== tabsSlot) {
        setTabsSlot(el);
      }
      if (!el && attempts < maxAttempts) {
        frame = requestAnimationFrame(tick);
      }
    };
    tick();
    return () => {
      cancelled = true;
      cancelAnimationFrame(frame);
    };
  }, [tabsSlot]);

  return (
    <main className="relative flex h-screen w-full flex-col overflow-y-hidden bg-[#111111]">
      <div className="relative flex min-h-0 flex-1 flex-col">
        <DashboardFloatingChrome scrollRoot={scrollRoot} alignToContent />
        {tabsSlot &&
          createPortal(
            <BrandInsightTabs visibleTabs={tabs} overflowTabs={[]} />,
            tabsSlot
          )}
        <div className="relative flex min-h-0 flex-1 flex-col">
          <div
            ref={bindScrollRoot}
            className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden bg-[#111111] pb-[max(1rem,env(safe-area-inset-bottom,0px))] pt-[calc(max(0.75rem,env(safe-area-inset-top,0px))+3.5rem)]"
          >
            <div className="mx-auto grid w-full min-w-0 max-w-[1392px] grid-cols-12 gap-x-6 px-4 py-6 sm:px-6 md:py-8 lg:px-8 lg:py-10 xl:px-0">
              <div className="col-span-12 min-w-0">{children}</div>
            </div>
          </div>
          <ScrollViewportEdgeFade />
        </div>
      </div>
    </main>
  );
}
```

Replace `src/app/share/brand/[slug]/layout.tsx` whole with:

```tsx
"use client";

import { useState, useEffect } from "react";
import { useParams, usePathname, useRouter } from "next/navigation";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { AxiosError } from "axios";
import { WallAccess, PageLoader } from "@/components/base";
import { InsightSurfaceLayout } from "@/components/insight-surface/InsightSurfaceLayout";
import { ShareInsightFrame } from "@/components/insight-surface/ShareInsightFrame";
import { getBrandShareInfo } from "@/services/query";
import { mutateBrandSharePassword } from "@/services/mutate";
import { PublicShareProvider } from "@/context/PublicShareContext";
import type { ResolvedMapEmbedded } from "@/lib/insightsTabResolution";

/**
 * The public share link of a brand's Insights (`/share/brand/{slug}`).
 * This file owns access only — the slug lookup, the password wall, the
 * share token. Tabs, redirects and the title row live in
 * `InsightSurfaceLayout`, shared with the client portal and the client
 * preview (spec 2026-10-07 §4.1); the floating chrome in
 * `ShareInsightFrame`. The tab inventory is `INSIGHT_SURFACE_TAB_KEYS`.
 */
export default function BrandShareLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const params = useParams();
  const pathname = usePathname();
  const router = useRouter();
  const slug = params.slug as string;

  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [accessToken, setAccessToken] = useState<string | null>(null);
  const queryClient = useQueryClient();

  // --- Slug lookup ---
  const { data, isLoading, isError } = useQuery({
    queryKey: ["brand-share-info", slug],
    queryFn: () => getBrandShareInfo(slug),
    retry: false,
    enabled: !!slug,
  });

  useEffect(() => {
    if (data?.access_token && !accessToken) {
      setAccessToken(data.access_token);
    }
  }, [data?.access_token]); // eslint-disable-line react-hooks/exhaustive-deps

  const isProtected = data?.is_protected ?? false;
  const brandId = data?.data?.brand_id ?? "";
  const brandName = data?.data?.brand_name ?? "";
  const brandLogo = data?.data?.brand_logo ?? null;
  const ownedMediaTableView = data?.data?.owned_media_table_view ?? null;

  // --- Password mutation ---
  const passwordMutation = useMutation({
    mutationFn: (password: string) => mutateBrandSharePassword(slug, password),
    onSuccess: (responseData) => {
      setIsAuthenticated(true);
      if (responseData.access_token) {
        setAccessToken(responseData.access_token);
      }
      // Protected links: `show()` returns a stub with no
      // `insights_tab_settings`, so the initial `["brand-share-info", slug]`
      // cache has no resolved override map and every tab renders with default
      // labels/visibility. The password response DOES carry the full payload
      // (resolver runs in `getBrandResponse`), so seed it into the same cache
      // key the layout reads from — otherwise brand label/visibility overrides
      // are silently ignored on protected links.
      if (responseData.data?.insights_tab_settings) {
        queryClient.setQueryData(["brand-share-info", slug], responseData);
      }
    },
  });

  const handleWallAccessSubmit = (password: string) => {
    passwordMutation.mutate(password);
  };

  // FR-13 / FR-22 (public share): the api embeds
  // `insights_tab_settings.resolved` on the share-info response.
  const resolvedMap = (data?.data as ResolvedMapEmbedded | undefined)
    ?.insights_tab_settings?.resolved;

  // --- Loading state ---
  if (isLoading) {
    return (
      <div className="bg-new-dark flex h-screen w-full items-center justify-center">
        <PageLoader variant="minimal" />
      </div>
    );
  }

  // --- Error / 404 → redirect to login ---
  if (isError) {
    router.push("/login");
    return null;
  }

  // --- Password wall ---
  if (isProtected && !isAuthenticated) {
    return (
      <WallAccess
        onSubmit={handleWallAccessSubmit}
        isLoading={passwordMutation.isPending}
        errorMessage={
          passwordMutation.error
            ? (passwordMutation.error as AxiosError<{ message: string }>)
                ?.response?.data?.message || "Incorrect password."
            : undefined
        }
      />
    );
  }

  // --- Authenticated / unprotected view ---
  return (
    <PublicShareProvider
      slug={slug}
      brandId={brandId}
      brandName={brandName}
      brandLogo={brandLogo}
      accessToken={accessToken}
      ownedMediaTableView={ownedMediaTableView}
    >
      <InsightSurfaceLayout
        resolved={resolvedMap}
        pathname={pathname}
        onNavigate={(href) => router.push(href)}
        onReplace={(href) => router.replace(href)}
        frame={ShareInsightFrame}
      >
        {children}
      </InsightSurfaceLayout>
    </PublicShareProvider>
  );
}
```

What moved where, so a reviewer can check nothing was dropped:

| Old layout piece | Now |
|---|---|
| `PUBLIC_SHARE_TAB_KEYS`, `TABS`, `SUBSET_DEFAULTS`, `visibleTabs` | `INSIGHT_SURFACE_TAB_KEYS` + `surfaceTabs(…, "public")` |
| `relativePath`, `matchedTab`, `activeTabId` | `relativeSurfacePath`, `matchSurfaceTab`, same fallback |
| The tabs-slot polling effect and the `<main>` chrome | `ShareInsightFrame` |
| The FR-25 redirect effect | `surfaceRedirect` + the layout's effect |
| `activeTabTitle`, `isSignalDetail`, `InsightPageHeaderRow` | the layout |

The redirect ran only after data loaded and the wall was passed. The layout only mounts in that state, so the timing is the same.

- [ ] **Step 8: Run — PASS, the mutations, and the neighbours**

```bash
cd WT && for f in src/components/insight-surface/InsightSurfaceLayout.test.tsx src/lib/insight-surface/tabs.test.ts src/components/frndos/DashboardFloatingChrome.test.tsx "src/app/share/dashboard/[slug]/page.test.tsx" src/constants/insightsTabs.test.ts; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: the new suites are green, and the old ones match Task 0. Apply the three layout mutations; each fails its named test. Restore.

- [ ] **Step 9: Manual smoke of the share link (Daffa's dev server or `cd WT && bun dev`)**

Open a brand's public link `/share/brand/{slug}` and click every tab. Check:
- Ads' Filters and date range land in the title row;
- a hidden-tab deep link lands on the first tab;
- a protected link shows its wall, then its labels.

Record ✓/✗ in the track. If no dev server is available, record "PENDING (Daffa)"; Task 14 repeats it.

- [ ] **Step 10: Lint, format, commit**

```bash
cd WT && F=(src/lib/insight-surface/tabs.ts src/lib/insight-surface/routes.ts src/lib/insight-surface/tabs.test.ts src/components/insight-surface/InsightSurfaceLayout.tsx src/components/insight-surface/ShareInsightFrame.tsx src/components/insight-surface/InsightSurfaceLayout.test.tsx "src/app/share/brand/[slug]/layout.tsx"); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" docs/tracks/client-portal.track.md && /usr/bin/git commit -F - <<'EOF'
refactor(web): InsightSurfaceLayout — one tab list, redirect and title row

Extracted from the /share/brand layout, which now owns access only (slug,
password wall, token) and passes its floating chrome as the frame. For a
client or the preview a tab shows only when its row opens it; a missing
map opens nothing. Spec 2026-10-07 §4.1, I-2.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 6: The BFF proxies the insight mirror; the middleware knows Insights URLs

**Files:**
- Modify: `src/lib/client-lane/portal/proxy.ts`
- Test: `src/lib/client-lane/portal/proxy.insights.test.ts` (create; `proxy.test.ts` is already 10.8 KB and stays as it is)
- Modify: `src/middleware.ts` (`portalPageSlugs` only)
- Test: `src/middleware.portal.test.ts` (append; 2.3 KB today)

**Interfaces:**
- Consumes: the existing `portalProxy`, `safeSegments`, `callApi`, `relay`.
- Produces:

```ts
export type PortalRoute =
  "me" | "approvals" | "code" | "code_verify" | "sign_out" | "insight_info" | "insight";
/** `rest` = the segments after `{ws}/{brand}/insight/`. */
export function insightRouteAllowed(method: string, rest: readonly string[]): boolean;
// portalRouteOf(method, ["fcn","acme","insight-info"]) === "insight_info"  (GET only)
// portalRouteOf(method, ["fcn","acme","insight", ...rest]) === "insight"   (when insightRouteAllowed)
// portalPageSlugs("/s/fcn/acme/insights/…") → { workspace: "fcn", brand: "acme" }
```

`portalProxy` needs no other change:
- the session header, the 401 cookie clear, the slide, the CSRF guard and `safeSegments` apply to the new routes as they are;
- the query string rides `request.nextUrl.search`.

- [ ] **Step 1: Write the failing proxy test**

Create `src/lib/client-lane/portal/proxy.insights.test.ts`:

```ts
import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { insightRouteAllowed, portalProxy, portalRouteOf } from "./proxy";

// Named mutations (plan Task 6):
// - allow any method in insightRouteAllowed → "refuses everything else" (DELETE row)
// - drop the `rest[1] !== "query"` guard → "refuses everything else" (GET reports/query)
// - return "insight" before checking insightRouteAllowed → "404s an insight path outside the mirror…"
// - drop safeSegments from portalProxy → the `signals/..` case of the same test

const TOKEN = "s".repeat(43);
const ORIGIN = "https://app.test";

function request(
  path: string,
  init: { method?: string; origin?: string; body?: string } = {}
) {
  return new NextRequest(new URL(`${ORIGIN}${path}`), {
    method: init.method ?? "GET",
    headers: {
      origin: init.origin ?? ORIGIN,
      cookie: `frnd_client=${TOKEN}`,
      ...(init.body ? { "content-type": "application/json" } : {}),
    },
    body: init.body,
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

const ALLOWED: Array<[string, string]> = [
  ["GET", "overview"],
  ["GET", "home"],
  ["GET", "signals"],
  ["GET", "signals/42"],
  ["GET", "reports"],
  ["GET", "reports/r1"],
  ["POST", "reports/query"],
  ["GET", "report-templates"],
  ["GET", "campaign"],
  ["GET", "campaign/filters"],
  ["GET", "paid-media/overview"],
  ["GET", "paid-media/detail"],
  ["GET", "paid-media/filters"],
  ["GET", "owned-media/overview"],
  ["GET", "owned-media/detail"],
  ["GET", "owned-media/sentiment"],
  ["GET", "owned-media/filters"],
  ["GET", "owned-media/label-attributes"],
  ["GET", "owned-media/creative/playbooks"],
  ["GET", "owned-media/creative/playbook"],
  ["GET", "owned-media/content/c9/creative-analysis"],
  ["GET", "earned-media"],
  ["GET", "earned-media/influencers"],
  ["GET", "earned-media/filters"],
  ["GET", "atl/overview"],
  ["GET", "atl/detail"],
  ["GET", "atl/filters"],
];

const REFUSED: Array<[string, string]> = [
  ["DELETE", "reports/r1"],
  ["POST", "signals"],
  ["PUT", "home"],
  ["GET", "reports/query"],
  ["POST", "reports/r1"],
  ["GET", "settings"],
  ["GET", "signals/42/bookmark"],
  ["GET", "owned-media/content/c9"],
  ["POST", "owned-media/content/c9/creative-analysis"],
  ["GET", "owned-media/creative/playbooks:generate"],
];

describe("insightRouteAllowed — the 27 mirrored share paths (spec 2026-10-07 §3.3)", () => {
  it("lists exactly 27 shapes", () => {
    expect(ALLOWED).toHaveLength(27);
  });

  it.each(ALLOWED)("allows %s %s", (method, path) => {
    expect(insightRouteAllowed(method, path.split("/"))).toBe(true);
  });

  it.each(REFUSED)("refuses everything else: %s %s", (method, path) => {
    expect(insightRouteAllowed(method, path.split("/"))).toBe(false);
  });
});

describe("portalRouteOf — Insights", () => {
  it("names the info and the insight endpoints", () => {
    expect(portalRouteOf("GET", ["fcn", "frndglow", "insight-info"])).toBe(
      "insight_info"
    );
    expect(
      portalRouteOf("GET", ["fcn", "frndglow", "insight", "paid-media", "detail"])
    ).toBe("insight");
    expect(
      portalRouteOf("POST", ["fcn", "frndglow", "insight", "reports", "query"])
    ).toBe("insight");
  });

  it("names nothing else under Insights", () => {
    expect(portalRouteOf("POST", ["fcn", "frndglow", "insight-info"])).toBeNull();
    expect(portalRouteOf("GET", ["fcn", "frndglow", "insight"])).toBeNull();
    expect(
      portalRouteOf("DELETE", ["fcn", "frndglow", "insight", "reports", "r1"])
    ).toBeNull();
  });
});

describe("portalProxy — Insights through the BFF (spec 2026-10-07 §4.2)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    process.env.NEXT_PUBLIC_API_URL = "https://api.test";
  });

  it("forwards an insight read with the session and its query, never a share token", async () => {
    const spy = apiAnswers(200, { data: { rows: [] } });
    const res = await portalProxy(
      request(
        "/s/api/portal/fcn/frndglow/insight/paid-media/detail?start_date=2026-01-01&platform%5B%5D=meta"
      ),
      ["fcn", "frndglow", "insight", "paid-media", "detail"]
    );
    expect(res.status).toBe(200);
    const [url, init] = spy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(
      "https://api.test/public/portal/fcn/frndglow/insight/paid-media/detail?start_date=2026-01-01&platform%5B%5D=meta"
    );
    const headers = new Headers(init.headers);
    expect(headers.get("X-Client-Session")).toBe(TOKEN);
    expect(headers.get("X-Share-Token")).toBeNull();
  });

  it("forwards the insight-info read", async () => {
    const spy = apiAnswers(200, { data: { brand_id: "b1" } });
    const res = await portalProxy(
      request("/s/api/portal/fcn/frndglow/insight-info"),
      ["fcn", "frndglow", "insight-info"]
    );
    expect(res.status).toBe(200);
    expect((spy.mock.calls[0] as [string])[0]).toBe(
      "https://api.test/public/portal/fcn/frndglow/insight-info"
    );
  });

  it("404s an insight path outside the mirror without calling the api", async () => {
    const spy = vi.spyOn(globalThis, "fetch");
    for (const segments of [
      ["fcn", "frndglow", "insight", "settings"],
      ["fcn", "frndglow", "insight", "signals", ".."],
    ]) {
      const res = await portalProxy(
        request(`/s/api/portal/${segments.join("/")}`),
        segments
      );
      expect(res.status).toBe(404);
    }
    expect(spy).not.toHaveBeenCalled();
  });

  it("refuses a cross-site report query", async () => {
    const spy = vi.spyOn(globalThis, "fetch");
    const res = await portalProxy(
      request("/s/api/portal/fcn/frndglow/insight/reports/query", {
        method: "POST",
        origin: "https://evil.test",
        body: JSON.stringify({ brandId: "b1", spec: {} }),
      }),
      ["fcn", "frndglow", "insight", "reports", "query"]
    );
    expect(res.status).toBe(403);
    expect(spy).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run it — FAIL**

Run: `cd WT && bun test src/lib/client-lane/portal/proxy.insights.test.ts`
Expected: an import failure (`insightRouteAllowed` is not exported).

- [ ] **Step 3: Implement**

In `src/lib/client-lane/portal/proxy.ts`:

(a) Replace

```ts
export type PortalRoute =
  "me" | "approvals" | "code" | "code_verify" | "sign_out";
```

with

```ts
export type PortalRoute =
  | "me"
  | "approvals"
  | "code"
  | "code_verify"
  | "sign_out"
  | "insight_info"
  | "insight";

/**
 * The share insight endpoints the portal mirrors (spec 2026-10-07 §3.3) —
 * every GET the share pages read, exactly. Ids are matched by shape below.
 */
const INSIGHT_GET_PATHS = new Set([
  "overview",
  "home",
  "signals",
  "reports",
  "report-templates",
  "campaign",
  "campaign/filters",
  "paid-media/overview",
  "paid-media/detail",
  "paid-media/filters",
  "owned-media/overview",
  "owned-media/detail",
  "owned-media/sentiment",
  "owned-media/filters",
  "owned-media/label-attributes",
  "owned-media/creative/playbooks",
  "owned-media/creative/playbook",
  "earned-media",
  "earned-media/influencers",
  "earned-media/filters",
  "atl/overview",
  "atl/detail",
  "atl/filters",
]);

/**
 * One of the 27 mirrored insight shapes (`rest` = the segments after
 * `{ws}/{brand}/insight/`): reads only, plus the report query POST.
 */
export function insightRouteAllowed(
  method: string,
  rest: readonly string[]
): boolean {
  if (method === "POST") {
    return rest.length === 2 && rest[0] === "reports" && rest[1] === "query";
  }
  if (method !== "GET") return false;
  if (INSIGHT_GET_PATHS.has(rest.join("/"))) return true;
  const n = rest.length;
  if (n === 2 && rest[0] === "signals") return true;
  if (n === 2 && rest[0] === "reports" && rest[1] !== "query") return true;
  return (
    n === 4 &&
    rest[0] === "owned-media" &&
    rest[1] === "content" &&
    rest[3] === "creative-analysis"
  );
}
```

(b) In `portalRouteOf`, before the final `return null;`, add:

```ts
  if (n === 3 && segments[2] === "insight-info" && method === "GET") {
    return "insight_info";
  }
  if (
    n >= 4 &&
    segments[2] === "insight" &&
    insightRouteAllowed(method, segments.slice(3))
  ) {
    return "insight";
  }
```

(c) Extend the header comment's bullet "Only the portal's own endpoint shapes are proxied" with: `— Approvals, sign-in, and (spec 2026-10-07) the 27 mirrored insight reads plus insight-info`.

- [ ] **Step 4: Run — PASS, the mutations, and the old proxy suite**

```bash
cd WT && bun test src/lib/client-lane/portal/proxy.insights.test.ts && bun test src/lib/client-lane/portal/proxy.test.ts
```

Expected: the new suite is green, and the old suite matches Task 0. Apply the four mutations; each fails its named test. Restore.

- [ ] **Step 5: The middleware — failing tests first**

Append to `src/middleware.portal.test.ts`:

```ts
// Named mutation (plan Task 6): drop the `(?:\/insights(?:\/[^/]+)*)?` group
// → "reads the brand of an Insights URL" and "captures ?k= on an Insights URL".

describe("portalPageSlugs — Insights (spec 2026-10-07 §4.2)", () => {
  it("reads the brand of an Insights URL", () => {
    expect(portalPageSlugs("/s/fcn/frndglow/insights")).toEqual({
      workspace: "fcn",
      brand: "frndglow",
    });
    expect(portalPageSlugs("/s/fcn/frndglow/insights/campaigns/r1")).toEqual({
      workspace: "fcn",
      brand: "frndglow",
    });
  });

  it("still refuses other deeper paths", () => {
    expect(portalPageSlugs("/s/fcn/frndglow/insightsx")).toBeNull();
    expect(portalPageSlugs("/s/fcn/frndglow/x/insights")).toBeNull();
    expect(portalPageSlugs("/s/api/portal/insights")).toBeNull();
  });

  it("captures ?k= on an Insights URL", () => {
    const res = middleware(
      request(`/s/fcn/frndglow/insights/paid-media?k=${LANE}`)
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "https://app.frnd.io/s/fcn/frndglow/insights/paid-media"
    );
    expect(res.cookies.get("frnd_lane")?.value).toBe(LANE);
    expect(res.cookies.get("frnd_lane_new")?.value).toBe("1");
  });
});
```

Run: `cd WT && bun test src/middleware.portal.test.ts`
Expected: the two named tests FAIL. "still refuses…" passes already, and so does every old test.

- [ ] **Step 6: Implement the regex**

In `src/middleware.ts`, in `portalPageSlugs`:
- replace

```ts
  const match = /^\/s\/([^/]+)\/([^/]+)\/?$/.exec(pathname);
```

  with

```ts
  // `/s/{ws}/{brand}` and its Insights pages (spec 2026-10-07 §4.2).
  const match = /^\/s\/([^/]+)\/([^/]+)(?:\/insights(?:\/[^/]+)*)?\/?$/.exec(
    pathname
  );
```

- and extend its doc comment's first line to "…— `/s/{workspace}/{brand}` and `/s/{workspace}/{brand}/insights/…`".

Run: `cd WT && bun test src/middleware.portal.test.ts && bun test src/middleware.mobile.test.ts && bun test src/middleware.kvShare.test.ts`
Expected: green; the old files match Task 0. Apply the mutation from the test header; both named tests fail. Restore. Phones are already admitted: `/s` is in `MOBILE_ALLOWED_ROUTES`, and prefix matching admits `/s/**`.

- [ ] **Step 7: Lint, format, commit**

```bash
cd WT && F=(src/lib/client-lane/portal/proxy.ts src/lib/client-lane/portal/proxy.insights.test.ts src/middleware.ts src/middleware.portal.test.ts); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): the portal BFF proxies the Insights mirror; ?k= works on Insights URLs

portalRouteOf admits insight-info and exactly the 27 share insight shapes
(GET only, plus the report query POST); everything else under insight/
404s without calling the api, and safeSegments still guards every
segment. portalPageSlugs reads /s/{ws}/{brand}/insights/**.
Spec 2026-10-07 §4.2.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 7: Analytics helpers for the three Insights events

**Files:**
- Modify: `src/lib/analytics/client-lane-events.ts`
- Modify: `src/lib/analytics/brand-settings-events.ts`
- Test: `src/lib/analytics/insights-client.events.test.ts` (create)

**Interfaces:**
- Consumes: `SurfaceTabKey` (Task 4).
- Produces:

```ts
// client-lane-events.ts — PUBLIC, PII-free
export const trackPortalInsightsViewed: (props: { tab: SurfaceTabKey }) => void;
// brand-settings-events.ts — agency; base context is automatic, never brand_id
export const trackInsightsTabClientVisibilityChanged: (props: { tab: SurfaceTabKey; visible: boolean }) => void;
export const trackInsightsPreviewAsClientOpened: () => void;
```

Load `frndos-analytics-events` before this task. The names are the spec's (§4.5).
- The public one joins the dot-namespaced `client_lane.*` domain.
- The two agency ones are flat, as the spec names them, and live with the other brand-settings events. Unlike that file's older wrappers, they never hand-pass `brand_id`.

- [ ] **Step 1: Write the failing test**

Create `src/lib/analytics/insights-client.events.test.ts`:

```ts
import posthog from "posthog-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  trackInsightsPreviewAsClientOpened,
  trackInsightsTabClientVisibilityChanged,
} from "./brand-settings-events";
import { trackPortalInsightsViewed } from "./client-lane-events";

// Named mutation (plan Task 7): misspell one name (e.g.
// "client_lane.portal_insight_viewed") → "fires each event under its
// taxonomy name"; add `brand_id` to an agency helper → "never hand-passes
// base context".

describe("Insights events (spec 2026-10-07 §4.5)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("fires each event under its taxonomy name", () => {
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    trackPortalInsightsViewed({ tab: "paid-media" });
    trackInsightsTabClientVisibilityChanged({ tab: "business", visible: true });
    trackInsightsPreviewAsClientOpened();
    expect(capture.mock.calls.map(([name]) => name)).toEqual([
      "client_lane.portal_insights_viewed",
      "insights_tab_client_visibility_changed",
      "insights_preview_as_client_opened",
    ]);
    expect(capture.mock.calls[0][1]).toMatchObject({ tab: "paid-media" });
    expect(capture.mock.calls[1][1]).toMatchObject({
      tab: "business",
      visible: true,
    });
  });

  it("never hand-passes base context", () => {
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    trackPortalInsightsViewed({ tab: "overview" });
    trackInsightsTabClientVisibilityChanged({ tab: "atl", visible: false });
    trackInsightsPreviewAsClientOpened();
    for (const [, props] of capture.mock.calls) {
      expect(Object.keys(props as object).sort()).not.toContain("brand_id");
      expect(props).toHaveProperty("timestamp");
    }
  });
});
```

- [ ] **Step 2: Run it — FAIL**

Run: `cd WT && bun test src/lib/analytics/insights-client.events.test.ts`
Expected: an import failure naming the missing helpers.

- [ ] **Step 3: Implement**

In `src/lib/analytics/client-lane-events.ts`:
- add `import type { SurfaceTabKey } from "@/lib/insight-surface/tabs";` to the type imports;
- append after `trackPortalItemOpened`:

```ts
/**
 * A tab of the portal's Insights opened (spec 2026-10-07 §4.5) — once per
 * tab change within a page view, never on refetch. `tab` is the tab key.
 */
export const trackPortalInsightsViewed = (props: { tab: SurfaceTabKey }) =>
  safeCapture("client_lane.portal_insights_viewed", props);
```

In `src/lib/analytics/brand-settings-events.ts`:
- add `import type { SurfaceTabKey } from "@/lib/insight-surface/tabs";` under the `posthog` import;
- append:

```ts
/**
 * Insights Tabs → a tab's Clients tick changed and was SAVED (spec
 * 2026-10-07 §4.5) — one event per tab whose value changed, after the save
 * succeeds. No `brand_id`: base context is registered (analytics skill).
 */
export const trackInsightsTabClientVisibilityChanged = (params: {
  tab: SurfaceTabKey;
  visible: boolean;
}) => {
  try {
    posthog.capture("insights_tab_client_visibility_changed", {
      ...params,
      timestamp: new Date().toISOString(),
    });
  } catch {
    // analytics never breaks the app
  }
};

/** Insights Tabs → "Preview as client" opened (spec 2026-10-07 §4.5). */
export const trackInsightsPreviewAsClientOpened = () => {
  try {
    posthog.capture("insights_preview_as_client_opened", {
      timestamp: new Date().toISOString(),
    });
  } catch {
    // analytics never breaks the app
  }
};
```

- [ ] **Step 4: Run — PASS, the mutation, the neighbour**

Run: `cd WT && bun test src/lib/analytics/insights-client.events.test.ts && bun test src/lib/analytics/client-lane-events.portal.test.ts`
Expected: green, and the neighbour matches Task 0. Apply both mutations; each fails its named test. Restore.

- [ ] **Step 5: Lint, format, commit**

```bash
cd WT && F=(src/lib/analytics/client-lane-events.ts src/lib/analytics/brand-settings-events.ts src/lib/analytics/insights-client.events.test.ts); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): analytics helpers for portal Insights, client visibility, preview

client_lane.portal_insights_viewed {tab} (public, PII-free);
insights_tab_client_visibility_changed {tab, visible} and
insights_preview_as_client_opened (agency, base context automatic).
Spec 2026-10-07 §4.5.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 8: `insight-info` rules, the server read, and Insights in the portal nav

**Files:**
- Create: `src/lib/client-lane/portal/insightInfo.ts`
- Test: `src/lib/client-lane/portal/insightInfo.test.ts` (create)
- Create: `src/lib/client-lane/portal/insightInfoServer.ts`
- Test: `src/lib/client-lane/portal/insightInfoServer.test.ts` (create)
- Modify: `src/lib/client-lane/portal/server.ts`
- Modify: `src/lib/client-lane/portal/shell.ts`
- Modify: `src/components/client-lane/portal/PortalNav.tsx`
- Modify: `src/components/client-lane/portal/PortalApp.tsx`
- Modify: `src/components/client-lane/portal/PortalApp.test.tsx` (7.6 KB today)
- Modify: `src/app/s/[token]/[brand]/page.tsx`

**Interfaces:**
- Consumes: `surfaceTabs`, `ResolvedTabMap`, `INSIGHT_SURFACE_TAB_KEYS` (Tasks 4–5); `SESSION_HEADER`, `apiBase` (`proxy.ts`); `portalHref` (`shell.ts`); `OwnedMediaTableView` (type, `@/context/PublicShareContext`).
- Produces:

```ts
// src/lib/client-lane/portal/insightInfo.ts (pure; safe in client bundles)
export interface PortalInsightInfo {
  brandId: string;
  brandName: string;
  brandLogo: string | null;
  ownedMediaTableView: OwnedMediaTableView | null;
  resolved: ResolvedTabMap;
}
export function normaliseInsightInfo(json: unknown): PortalInsightInfo | null;
export function hasClientInsights(info: PortalInsightInfo): boolean;
export type InsightErrorAction = "sign_in" | "recheck" | "none";
export function insightErrorAction(status: number | null): InsightErrorAction;

// src/lib/client-lane/portal/insightInfoServer.ts (server only)
export function fetchPortalInsightInfoForSession(
  sessionToken: string, workspaceSlug: string, brandSlug: string
): Promise<PortalInsightInfo | null>; // null on 401/403/404; throws on other failures

// src/lib/client-lane/portal/server.ts (added)
export const resolvePortalInsightInfoServer: typeof fetchPortalInsightInfoForSession; // React cache()

// src/lib/client-lane/portal/shell.ts (added)
export function portalInsightsHref(b: Pick<PortalBrand, "workspace" | "brand">): string; // portalHref(b) + "/insights"

// PortalNav
export function PortalNav(props: {
  waiting: number;
  active?: "approvals" | "insights"; // default "approvals"
  approvalsHref: string;
  insightsHref?: string | null;      // no Insights item when null
  onNavigate?: (href: string) => void; // default window.location.assign
}): JSX.Element;

// PortalApp: new optional prop `insightsHref?: string | null`
```

What a 404 means differs between the two portal pages:
- In **Approvals**, it means the brand is gone (`portalErrorAction`).
- In **Insights**, it may mean only that one tab was unticked. So `insightErrorAction` answers `"recheck"`: Task 9 re-reads `insight-info` and lets that answer decide.

- [ ] **Step 1: Write the failing rules tests**

Create `src/lib/client-lane/portal/insightInfo.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  hasClientInsights,
  insightErrorAction,
  normaliseInsightInfo,
} from "./insightInfo";

// Named mutations (plan Task 8):
// - read `is_visible !== false` instead of `=== true` → "opens only the rows that say so"
// - drop the `tabs` fallback → "accepts the spec's flat spelling"
// - map 404 to "sign_in" → "rechecks a 404"

describe("normaliseInsightInfo (spec 2026-10-07 §3.3, assumed shape)", () => {
  it("reads the getBrandResponse shape", () => {
    expect(
      normaliseInsightInfo({
        data: {
          brand_id: "01brand",
          brand_name: "frndGlow",
          brand_logo: "https://cdn.test/logo.png",
          owned_media_table_view: { visibleColIds: ["reach"] },
          insights_tab_settings: {
            resolved: {
              overview: { label: "Overview", is_visible: true },
              business: { label: "Business", is_visible: false },
              dashboard: { label: "Dashboard", is_visible: true },
            },
          },
        },
      })
    ).toEqual({
      brandId: "01brand",
      brandName: "frndGlow",
      brandLogo: "https://cdn.test/logo.png",
      ownedMediaTableView: { visibleColIds: ["reach"] },
      resolved: {
        overview: { label: "Overview", is_visible: true },
        business: { label: "Business", is_visible: false },
      },
    });
  });

  it("accepts the spec's flat spelling, tabs as a list", () => {
    const info = normaliseInsightInfo({
      data: {
        brand_id: "01brand",
        name: "frndGlow",
        logo: null,
        tabs: [
          { id: "paid-media", label: "Ads", is_visible: true },
          { key: "atl", label: "", is_visible: true },
        ],
      },
    });
    expect(info?.brandName).toBe("frndGlow");
    expect(info?.resolved).toEqual({
      "paid-media": { label: "Ads", is_visible: true },
      atl: { label: "ATL", is_visible: true },
    });
  });

  it("opens only the rows that say so", () => {
    const info = normaliseInsightInfo({
      brand_id: "01brand",
      insights_tab_settings: {
        resolved: { overview: { label: "Overview" } },
      },
    });
    expect(info?.resolved.overview?.is_visible).toBe(false);
    expect(hasClientInsights(info!)).toBe(false);
  });

  it("refuses a payload without a brand", () => {
    expect(normaliseInsightInfo({ data: {} })).toBeNull();
    expect(normaliseInsightInfo(null)).toBeNull();
  });
});

describe("hasClientInsights", () => {
  it("is true with one open tab", () => {
    const info = normaliseInsightInfo({
      brand_id: "b",
      tabs: { signals: { label: "Trends", is_visible: true } },
    })!;
    expect(hasClientInsights(info)).toBe(true);
  });
});

describe("insightErrorAction", () => {
  it("signs in on 401 and rechecks a 404", () => {
    expect(insightErrorAction(401)).toBe("sign_in");
    expect(insightErrorAction(404)).toBe("recheck");
  });
  it("leaves other failures to the page", () => {
    expect(insightErrorAction(500)).toBe("none");
    expect(insightErrorAction(null)).toBe("none");
  });
});
```

Create `src/lib/client-lane/portal/insightInfoServer.test.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

import { fetchPortalInsightInfoForSession } from "./insightInfoServer";

// Named mutation (plan Task 8): return null on any non-200 → "throws on an outage".

const TOKEN = "s".repeat(43);

function apiAnswers(status: number, body: unknown) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    })
  );
}

describe("fetchPortalInsightInfoForSession (spec 2026-10-07 §3.3)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    process.env.NEXT_PUBLIC_API_URL = "https://api.test";
  });

  it("asks the api with the session header, never a cache", async () => {
    const spy = apiAnswers(200, {
      data: {
        brand_id: "01brand",
        brand_name: "frndGlow",
        insights_tab_settings: {
          resolved: { overview: { label: "Overview", is_visible: true } },
        },
      },
    });
    const info = await fetchPortalInsightInfoForSession(TOKEN, "fcn", "frnd glow");
    expect(info?.brandId).toBe("01brand");
    const [url, init] = spy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(
      "https://api.test/public/portal/fcn/frnd%20glow/insight-info"
    );
    expect(new Headers(init.headers).get("X-Client-Session")).toBe(TOKEN);
    expect(init.cache).toBe("no-store");
  });

  it("reads a lost session, a revoked lane and a refusal as nothing to show", async () => {
    for (const status of [401, 403, 404]) {
      vi.restoreAllMocks();
      apiAnswers(status, { message: "no" });
      await expect(
        fetchPortalInsightInfoForSession(TOKEN, "fcn", "frndglow")
      ).resolves.toBeNull();
    }
  });

  it("throws on an outage", async () => {
    apiAnswers(503, { message: "down" });
    await expect(
      fetchPortalInsightInfoForSession(TOKEN, "fcn", "frndglow")
    ).rejects.toThrow("503");
  });
});
```

- [ ] **Step 2: Run them — FAIL**

```bash
cd WT && bun test src/lib/client-lane/portal/insightInfo.test.ts; bun test src/lib/client-lane/portal/insightInfoServer.test.ts
```

Expected: both fail at import.

- [ ] **Step 3: Implement the rules and the server read**

Create `src/lib/client-lane/portal/insightInfo.ts`:

```ts
/**
 * The portal's `insight-info` (spec 2026-10-07 §3.3): the brand and the
 * tabs open to clients. Pure — no fetch, no `next/server` — so client and
 * server code both import it. The api plan's exact keys are reconciled in
 * Task 14; until then both spellings the spec mentions are read.
 */
import { GLOBAL_INSIGHTS_TABS_BY_KEY } from "@/constants/insightsTabs";
import type { OwnedMediaTableView } from "@/context/PublicShareContext";
import {
  isSurfaceTabKey,
  surfaceTabs,
  type ResolvedTabMap,
} from "@/lib/insight-surface/tabs";

export interface PortalInsightInfo {
  brandId: string;
  brandName: string;
  brandLogo: string | null;
  ownedMediaTableView: OwnedMediaTableView | null;
  /** Rows the api sent, surface tabs only; `is_visible` = open to clients. */
  resolved: ResolvedTabMap;
}

type Row = { id?: unknown; key?: unknown; label?: unknown; is_visible?: unknown };

const str = (value: unknown): string | undefined =>
  typeof value === "string" ? value : undefined;

function toResolvedMap(raw: unknown): ResolvedTabMap {
  const out: ResolvedTabMap = {};
  const put = (key: unknown, row: Row | null | undefined) => {
    if (typeof key !== "string" || !isSurfaceTabKey(key)) return;
    const label = str(row?.label)?.trim();
    out[key] = {
      label: label || GLOBAL_INSIGHTS_TABS_BY_KEY[key].label,
      // Least privilege: only an explicit `true` opens a tab to clients.
      is_visible: row?.is_visible === true,
    };
  };
  if (Array.isArray(raw)) {
    for (const row of raw as Row[]) put(row?.id ?? row?.key, row);
  } else if (raw && typeof raw === "object") {
    for (const [key, row] of Object.entries(raw as Record<string, Row>)) {
      put(key, row);
    }
  }
  return out;
}

export function normaliseInsightInfo(json: unknown): PortalInsightInfo | null {
  if (!json || typeof json !== "object") return null;
  const root = json as { data?: unknown };
  const data = (
    root.data && typeof root.data === "object" ? root.data : root
  ) as Record<string, unknown>;
  const brandId = str(data.brand_id);
  if (!brandId) return null;
  const settings = data.insights_tab_settings as
    | { resolved?: unknown }
    | undefined;
  return {
    brandId,
    brandName: str(data.brand_name) ?? str(data.name) ?? "",
    brandLogo: str(data.brand_logo) ?? str(data.logo) ?? null,
    ownedMediaTableView:
      (data.owned_media_table_view as OwnedMediaTableView | null | undefined) ??
      null,
    resolved: toResolvedMap(settings?.resolved ?? data.tabs),
  };
}

/** At least one tab is open to clients — Insights shows in the portal nav. */
export function hasClientInsights(info: PortalInsightInfo): boolean {
  return surfaceTabs(info.resolved, "client").length > 0;
}

export type InsightErrorAction = "sign_in" | "recheck" | "none";

/**
 * What an Insights call's failure means (spec 2026-10-07 §3.2): 401 = the
 * session is gone; 404 = this tab was closed to clients OR the lane was
 * revoked — re-read insight-info to know which; anything else is the
 * page's own error state.
 */
export function insightErrorAction(status: number | null): InsightErrorAction {
  if (status === 401) return "sign_in";
  if (status === 404) return "recheck";
  return "none";
}
```

Create `src/lib/client-lane/portal/insightInfoServer.ts`:

```ts
/**
 * `GET public/portal/{ws}/{brand}/insight-info` from the SERVER (the portal
 * pages' server components). Plain `fetch`, `no-store`: a revoked lane or
 * an unticked tab must never render from a stale copy. Null = nothing to
 * show (401 / 403 / 404); any other failure throws, so the route's error
 * boundary shows rather than a page lying about an outage.
 */
import { normaliseInsightInfo, type PortalInsightInfo } from "./insightInfo";
import { SESSION_HEADER, apiBase } from "./proxy";

export async function fetchPortalInsightInfoForSession(
  sessionToken: string,
  workspaceSlug: string,
  brandSlug: string
): Promise<PortalInsightInfo | null> {
  const path = `${encodeURIComponent(workspaceSlug)}/${encodeURIComponent(brandSlug)}`;
  const res = await fetch(`${apiBase()}/public/portal/${path}/insight-info`, {
    headers: { Accept: "application/json", [SESSION_HEADER]: sessionToken },
    cache: "no-store",
  });
  if (res.status === 401 || res.status === 403 || res.status === 404) {
    return null;
  }
  if (!res.ok) throw new Error(`portal insight-info failed: ${res.status}`);
  return normaliseInsightInfo(await res.json());
}
```

In `src/lib/client-lane/portal/server.ts`, append:

```ts
import { fetchPortalInsightInfoForSession } from "./insightInfoServer";

/** One insight-info call per request, shared by the Approvals page and the Insights layout. */
export const resolvePortalInsightInfoServer = cache(
  fetchPortalInsightInfoForSession
);
```

Move the new `import` up beside the existing `import { fetchPortalMe } from "./me";`.

In `src/lib/client-lane/portal/shell.ts`, after `portalHref`:

```ts
/** The brand's Insights in the portal (spec 2026-10-07 §4.2). */
export function portalInsightsHref(b: Slugs): string {
  return `${portalHref(b)}/insights`;
}
```

and append to `src/lib/client-lane/portal/shell.test.ts` (3.7 KB). Add `portalInsightsHref` to its `./shell` import, and add:

```ts
describe("portalInsightsHref (spec 2026-10-07 §4.2)", () => {
  it("is the brand's portal plus /insights, encoded the same way", () => {
    expect(
      portalInsightsHref({
        workspace: { name: "FCN", slug: "fcn" },
        brand: { name: "frnd Glow", slug: "frnd glow", logo_url: null },
      })
    ).toBe("/s/fcn/frnd%20glow/insights");
  });
});
```

- [ ] **Step 4: Run — PASS, then the mutations**

```bash
cd WT && for f in src/lib/client-lane/portal/insightInfo.test.ts src/lib/client-lane/portal/insightInfoServer.test.ts src/lib/client-lane/portal/shell.test.ts src/lib/client-lane/portal/me.test.ts; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: green, and `me.test.ts` matches Task 0. Apply the four named mutations; each fails its named test. Restore.

- [ ] **Step 5: Change the PortalApp test to the new nav — failing first**

In `src/components/client-lane/portal/PortalApp.test.tsx`, replace

```tsx
    // Insights is shown, but not yet a place to go.
    expect(body().getByRole("button", { name: /Insights/ })).toBeDisabled();
```

with

```tsx
    // No tab is open to clients here, so Insights is not offered at all
    // (spec 2026-10-07 §4.2).
    expect(body().queryByRole("button", { name: /Insights/ })).toBeNull();
```

and append, before the final `});` of the `describe`:

```tsx
  it("opens Insights when a tab is open to clients", async () => {
    const user = userEvent.setup();
    stubApprovals({ first: portalApprovals() });
    const onNavigate = vi.fn();
    renderApp({ onNavigate, insightsHref: "/s/fcn/frndglow/insights" });
    const insights = await body().findByRole("button", { name: /Insights/ });
    expect(insights).toBeEnabled();
    expect(body().queryByText("Soon")).toBeNull();
    await user.click(insights);
    expect(onNavigate).toHaveBeenCalledWith("/s/fcn/frndglow/insights");
  });
```

Add this line to the file's mutation header:

```tsx
// - render the Insights item whatever insightsHref is → "groups the inbox…" (the Insights assert)
// - ignore insightsHref in onValueChange → "opens Insights when a tab is open to clients"
```

Run: `cd WT && bun test src/components/client-lane/portal/PortalApp.test.tsx`
Expected: two failures:
- the first test (the Insights button still renders, disabled);
- the new test (`insightsHref` is not a prop yet, so the button is disabled).

- [ ] **Step 6: Implement the nav, the app prop and the page**

Replace `src/components/client-lane/portal/PortalNav.tsx` whole with:

```tsx
"use client";

import { CountBadge, SegmentedTabs } from "@/components/frndos/v2";

type PortalSection = "approvals" | "insights";

/**
 * The portal's sections (spec 2026-10-06 portal §6.2; 2026-10-07 §4.2), the
 * centre of the top bar: "Approvals" with its waiting count, and "Insights"
 * only when at least one Insights tab is open to clients (`insightsHref`).
 * `CountBadge` is aria-hidden, so the count is repeated for screen readers.
 */
export function PortalNav({
  waiting,
  active = "approvals",
  approvalsHref,
  insightsHref = null,
  onNavigate = (href) => window.location.assign(href),
}: {
  waiting: number;
  active?: PortalSection;
  approvalsHref: string;
  insightsHref?: string | null;
  onNavigate?: (href: string) => void;
}) {
  const items: Array<{ value: PortalSection; label: React.ReactNode }> = [
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
  ];
  if (insightsHref) items.push({ value: "insights", label: "Insights" });

  return (
    <SegmentedTabs
      aria-label="Portal sections"
      value={active}
      onValueChange={(next) =>
        onNavigate(
          next === "insights" && insightsHref ? insightsHref : approvalsHref
        )
      }
      items={items}
    />
  );
}
```

If tsc rejects the bare `React.ReactNode` (no `React` in scope), add `import type { ReactNode } from "react";` and use `ReactNode`.

In `src/components/client-lane/portal/PortalApp.tsx`:
- change `import { brandKey, portalErrorAction } from "@/lib/client-lane/portal/shell";` to `import { brandKey, portalErrorAction, portalHref } from "@/lib/client-lane/portal/shell";`;
- add the prop (destructure and type):

```tsx
  insightsHref = null,
```

```tsx
  /** The brand's Insights, when at least one tab is open to clients. */
  insightsHref?: string | null;
```

- replace the `nav={…}` prop with

```tsx
        nav={
          <PortalNav
            waiting={view?.waiting_on_you.length ?? current.waiting_on_you}
            approvalsHref={portalHref(current)}
            insightsHref={insightsHref}
            onNavigate={onNavigate}
          />
        }
```

In `src/app/s/[token]/[brand]/page.tsx`:
- add `portalInsightsHref` to the `shell` import;
- import `{ hasClientInsights } from "@/lib/client-lane/portal/insightInfo"`;
- add `resolvePortalInsightInfoServer` to the `server` import;
- replace

```tsx
    if (me && current) return <PortalApp me={me} current={current} />;
```

  with

```tsx
    if (me && current) {
      // Insights shows only when a tab is open to clients (spec 2026-10-07
      // §4.2). An outage there must not take Approvals down with it.
      const info = await resolvePortalInsightInfoServer(
        session,
        workspaceSlug,
        brandSlug
      ).catch(() => null);
      const insightsHref =
        info && hasClientInsights(info) ? portalInsightsHref(current) : null;
      return (
        <PortalApp me={me} current={current} insightsHref={insightsHref} />
      );
    }
```

- [ ] **Step 7: Run — PASS, the mutations, the neighbours**

```bash
cd WT && for f in src/components/client-lane/portal/PortalApp.test.tsx src/components/client-lane/portal/PortalHeader.test.tsx src/lib/client-lane/tokenHygiene.test.ts; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: green, and the neighbours match Task 0 (`tokenHygiene.test.ts` scans `PortalNav.tsx`). Apply the two PortalApp mutations; each fails its named test. Restore.

- [ ] **Step 8: Lint, format, commit**

```bash
cd WT && F=(src/lib/client-lane/portal/insightInfo.ts src/lib/client-lane/portal/insightInfo.test.ts src/lib/client-lane/portal/insightInfoServer.ts src/lib/client-lane/portal/insightInfoServer.test.ts src/lib/client-lane/portal/server.ts src/lib/client-lane/portal/shell.ts src/lib/client-lane/portal/shell.test.ts src/components/client-lane/portal/PortalNav.tsx src/components/client-lane/portal/PortalApp.tsx src/components/client-lane/portal/PortalApp.test.tsx "src/app/s/[token]/[brand]/page.tsx"); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): portal nav offers Insights when a tab is open to clients

insight-info is read server-side with the session (null on 401/403/404,
throws on an outage) and normalised — only an explicit is_visible opens
a tab. PortalNav drops the disabled "Soon" item: Insights appears only
with an href and navigates. Spec 2026-10-07 §3.3, §4.2.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 9: The portal Insights route — `/s/{ws}/{brand}/insights/[[...tab]]`

**Files:**
- Modify: `src/services/client-portal.ts`
- Test: `src/services/client-portal.insights.test.ts` (create)
- Modify: `src/components/client-lane/portal/PortalFrame.tsx` (`wide`)
- Create: `src/components/client-lane/portal/PortalInsightsApp.tsx`
- Test: `src/components/client-lane/portal/PortalInsightsApp.test.tsx` (create)
- Create: `src/components/client-lane/portal/PortalInsightsRoute.tsx`
- Create: `src/components/insight-surface/InsightSurfaceRoutePage.tsx`
- Create: `src/app/s/[token]/[brand]/insights/layout.tsx`
- Create: `src/app/s/[token]/[brand]/insights/[[...tab]]/page.tsx`
- Modify: `src/components/brands/reports/ReportView.tsx` (creator row guard only)

**Interfaces:**
- Consumes:
  - `PortalInsightInfo`, `normaliseInsightInfo`, `hasClientInsights`, `insightErrorAction` and `resolvePortalInsightInfoServer` (Task 8);
  - `portalHref`, `portalInsightsHref`, `portalErrorAction` and `findPortalBrand` (`shell.ts`);
  - `portalInsightSurface` (Task 2), `InsightSurfaceLayout` (Task 5), `InsightTabRouter` and `resolveInsightRoute` (Task 4);
  - `trackPortalInsightsViewed` (Task 7);
  - `PortalHeader`, `PortalNav` (Task 8), `PortalSignIn`, `PortalExchangeGate`, `resolvePortalMeServer`, `shouldExchangeLane` and the cookie names — all existing.
- Produces:

```ts
// src/services/client-portal.ts (added)
export const portalInsightInfoKey: (ws: string, brand: string) => readonly ["portal", string, string, "insight-info"];
export function isPortalInsightInfoKey(key: readonly unknown[]): boolean;
export function fetchPortalInsightInfo(ws: string, brand: string): Promise<PortalInsightInfo>; // via the BFF
export function usePortalInsightInfo(ws: string, brand: string, initialData: PortalInsightInfo): UseQueryResult<PortalInsightInfo>;

// PortalFrame: new optional prop `wide?: boolean` (max-w 1392px for Insights)

// src/components/client-lane/portal/PortalInsightsApp.tsx
export function PortalInsightsApp(props: {
  me: PortalMe;
  current: PortalBrand;
  info: PortalInsightInfo;           // the server's first read
  pathname: string;
  onNavigate: (href: string) => void;
  onReplace: (href: string) => void;
  onSessionLost?: () => void;        // default: window.location.reload()
  children: ReactNode;               // the [[...tab]] page body
}): JSX.Element;

// src/components/client-lane/portal/PortalInsightsRoute.tsx — usePathname/useRouter → PortalInsightsApp
export function PortalInsightsRoute(props: { me; current; info; children }): JSX.Element;

// src/components/insight-surface/InsightSurfaceRoutePage.tsx — default export, reads useParams().tab
```

Why the shell lives in the layout: a layout does not re-render on navigation (Next 16 `layout.md`). So the header, the nav and the tab strip stay mounted while only the `[[...tab]]` body changes, and the view event counts tab changes, not remounts.

The server layout does the access work, exactly as `[brand]/page.tsx` does:
- a fresh `?k=` lane → the exchange gate;
- no session, or no lane on this brand → the sign-in screen (no hint);
- no tab open to clients → `redirect()` to Approvals.

- [ ] **Step 1: Write the failing service test**

Create `src/services/client-portal.insights.test.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

import { axiosPublic } from "@/services/axios";

import {
  fetchPortalInsightInfo,
  isPortalInsightInfoKey,
  portalApprovalsKey,
  portalInsightInfoKey,
} from "./client-portal";

// Named mutations (plan Task 9):
// - drop `baseURL: PORTAL_PROXY_BASE` → "reads insight-info through the BFF…"
// - return `res.data` unnormalised → the same test (`brandId` missing)
// - check only key[0] in isPortalInsightInfoKey → "tells the info key from the approvals key"

describe("portal insight-info in the browser (spec 2026-10-07 §4.2)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("reads insight-info through the BFF and normalises it", async () => {
    const get = vi.spyOn(axiosPublic, "get").mockResolvedValue({
      data: {
        data: {
          brand_id: "01brand",
          brand_name: "frndGlow",
          insights_tab_settings: {
            resolved: { overview: { label: "Overview", is_visible: true } },
          },
        },
      },
    } as never);
    const info = await fetchPortalInsightInfo("fcn", "frnd glow");
    expect(get).toHaveBeenCalledWith("fcn/frnd%20glow/insight-info", {
      baseURL: "/s/api/portal/",
    });
    expect(info.brandId).toBe("01brand");
    expect(info.resolved.overview?.is_visible).toBe(true);
  });

  it("refuses a body without a brand", async () => {
    vi.spyOn(axiosPublic, "get").mockResolvedValue({ data: {} } as never);
    await expect(fetchPortalInsightInfo("fcn", "g")).rejects.toThrow();
  });

  it("tells the info key from the approvals key", () => {
    expect(isPortalInsightInfoKey(portalInsightInfoKey("fcn", "g"))).toBe(true);
    expect(isPortalInsightInfoKey(portalApprovalsKey("fcn", "g"))).toBe(false);
    expect(isPortalInsightInfoKey(["brand-share-home", "acme"])).toBe(false);
  });
});
```

Run: `cd WT && bun test src/services/client-portal.insights.test.ts`
Expected: FAIL at import.

- [ ] **Step 2: Implement the service additions**

In `src/services/client-portal.ts`:
- change `import { useInfiniteQuery } from "@tanstack/react-query";` to `import { useInfiniteQuery, useQuery } from "@tanstack/react-query";`;
- add the import

```ts
import {
  normaliseInsightInfo,
  type PortalInsightInfo,
} from "@/lib/client-lane/portal/insightInfo";
```

- and append:

```ts
/* ── Insights (spec 2026-10-07 §4.2) ─────────────────────────────────── */

export const portalInsightInfoKey = (workspaceSlug: string, brandSlug: string) =>
  ["portal", workspaceSlug, brandSlug, "insight-info"] as const;

export function isPortalInsightInfoKey(key: readonly unknown[]): boolean {
  return key[0] === "portal" && key[3] === "insight-info";
}

/** The brand and the tabs open to clients, re-read when an Insights call 404s. */
export async function fetchPortalInsightInfo(
  workspaceSlug: string,
  brandSlug: string
): Promise<PortalInsightInfo> {
  const res = await axiosPublic.get(
    `${brandPath(workspaceSlug, brandSlug)}/insight-info`,
    { baseURL: PORTAL_PROXY_BASE }
  );
  const info = normaliseInsightInfo(res.data);
  if (!info) throw new Error("insight-info answered without a brand");
  return info;
}

/**
 * Seeded by the server's read, never refetched on its own — only when an
 * Insights call answers 404 (`PortalInsightsApp`). Not retried: a 401/404
 * is an answer, not a blip.
 */
export function usePortalInsightInfo(
  workspaceSlug: string,
  brandSlug: string,
  initialData: PortalInsightInfo
) {
  return useQuery({
    queryKey: portalInsightInfoKey(workspaceSlug, brandSlug),
    queryFn: () => fetchPortalInsightInfo(workspaceSlug, brandSlug),
    initialData,
    staleTime: Infinity,
    refetchOnWindowFocus: false,
    retry: false,
  });
}
```

Run: `cd WT && bun test src/services/client-portal.insights.test.ts && bun test src/services/client-portal.test.ts`
Expected: green, and the old file matches Task 0. Apply the three mutations; each fails its named test. Restore.

- [ ] **Step 3: Write the failing shell test**

Create `src/components/client-lane/portal/PortalInsightsApp.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import {
  QueryClient,
  QueryClientProvider,
  useQuery,
} from "@tanstack/react-query";
import { cleanup, render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { StrictMode, useState, type ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { portalBrand, portalMe } from "@/lib/client-lane/portal/fixtures";
import type { PortalInsightInfo } from "@/lib/client-lane/portal/insightInfo";
import { axiosPublic } from "@/services/axios";

import { PortalInsightsApp } from "./PortalInsightsApp";

// Named mutations (plan Task 9):
// - drop the `lastViewed.current === tab` guard → "counts each tab view once"
//   (StrictMode double-runs the layout's effect; if this run shows no double
//   call even without the guard, the test is vacuous — say so in the track)
// - treat a 404 like a 401 (call onSessionLost directly) → "does not reload for a 404 when the brand is still open"
// - skip the info refetch on 404 → "rechecks access on a 404 and hands back to sign-in when the brand is gone"
// - drop the empty-info effect → "goes back to Approvals when no tab is open any more"
// - pass `active="approvals"` to PortalNav → "shows the open tabs under the portal header"

const body = () => within(document.body);
const BASE = "/s/fcn/frndglow/insights";

const INFO: PortalInsightInfo = {
  brandId: "01brand",
  brandName: "frndGlow",
  brandLogo: null,
  ownedMediaTableView: null,
  resolved: {
    overview: { label: "Overview", is_visible: true },
    "paid-media": { label: "Ads", is_visible: true },
    business: { label: "Business", is_visible: false },
  },
};

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function failure(status: number) {
  return Object.assign(new Error(`HTTP ${status}`), {
    response: { status, data: { message: "no" } },
  });
}

function FailingTab({ status }: { status: number }) {
  useQuery({
    queryKey: ["probe-tab", status],
    queryFn: async () => {
      throw failure(status);
    },
    retry: false,
  });
  return <p>tab content</p>;
}

const handlers = () => ({
  onNavigate: vi.fn(),
  onReplace: vi.fn(),
  onSessionLost: vi.fn(),
});

function app(
  pathname: string,
  h: ReturnType<typeof handlers>,
  children: ReactNode = <p>tab content</p>
) {
  return (
    <PortalInsightsApp
      me={portalMe()}
      current={portalBrand()}
      info={INFO}
      pathname={pathname}
      {...h}
    >
      {children}
    </PortalInsightsApp>
  );
}

function infoAnswers(resolved: Record<string, unknown>) {
  return vi.spyOn(axiosPublic, "get").mockResolvedValue({
    data: {
      data: {
        brand_id: "01brand",
        brand_name: "frndGlow",
        insights_tab_settings: { resolved },
      },
    },
  } as never);
}

describe("PortalInsightsApp (spec 2026-10-07 §4.2)", () => {
  beforeEach(() => vi.restoreAllMocks());
  afterEach(() => cleanup());

  it("shows the open tabs under the portal header, Insights selected", async () => {
    const user = userEvent.setup();
    const h = handlers();
    render(app(`${BASE}/paid-media`, h), { wrapper: QueryWrapper });
    expect(body().getByRole("button", { name: "Overview" })).toBeInTheDocument();
    expect(body().getByRole("button", { name: "Ads" })).toBeInTheDocument();
    expect(body().queryByRole("button", { name: "Business" })).toBeNull();
    expect(body().getByRole("button", { name: /Insights/ })).toHaveAttribute(
      "aria-pressed",
      "true"
    );
    expect(body().getByText("tab content")).toBeInTheDocument();

    await user.click(body().getByRole("button", { name: /Approvals/ }));
    expect(h.onNavigate).toHaveBeenCalledWith("/s/fcn/frndglow");
  });

  it("counts each tab view once", async () => {
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const h = handlers();
    // StrictMode runs every effect twice on mount — exactly the remount
    // churn the guard exists for.
    const { rerender } = render(
      <StrictMode>{app(`${BASE}/paid-media`, h)}</StrictMode>,
      { wrapper: QueryWrapper }
    );
    rerender(<StrictMode>{app(`${BASE}/paid-media`, h)}</StrictMode>);
    rerender(<StrictMode>{app(BASE, h)}</StrictMode>);
    const views = capture.mock.calls.filter(
      ([name]) => name === "client_lane.portal_insights_viewed"
    );
    expect(views.map(([, props]) => (props as { tab: string }).tab)).toEqual([
      "paid-media",
      "overview",
    ]);
  });

  it("goes back to sign-in on a 401 without re-reading", async () => {
    const get = vi.spyOn(axiosPublic, "get");
    const h = handlers();
    render(app(BASE, h, <FailingTab status={401} />), {
      wrapper: QueryWrapper,
    });
    await waitFor(() => expect(h.onSessionLost).toHaveBeenCalledTimes(1));
    expect(get).not.toHaveBeenCalled();
  });

  it("rechecks access on a 404 and hands back to sign-in when the brand is gone", async () => {
    const get = vi
      .spyOn(axiosPublic, "get")
      .mockRejectedValue(failure(404));
    const h = handlers();
    render(app(BASE, h, <FailingTab status={404} />), {
      wrapper: QueryWrapper,
    });
    await waitFor(() => expect(h.onSessionLost).toHaveBeenCalledTimes(1));
    expect(get).toHaveBeenCalledWith("fcn/frndglow/insight-info", {
      baseURL: "/s/api/portal/",
    });
  });

  it("goes back to Approvals when no tab is open any more", async () => {
    infoAnswers({ overview: { label: "Overview", is_visible: false } });
    const h = handlers();
    render(app(BASE, h, <FailingTab status={404} />), {
      wrapper: QueryWrapper,
    });
    await waitFor(() =>
      expect(h.onReplace).toHaveBeenCalledWith("/s/fcn/frndglow")
    );
    expect(h.onSessionLost).not.toHaveBeenCalled();
  });

  it("does not reload for a 404 when the brand is still open", async () => {
    const get = infoAnswers({
      overview: { label: "Overview", is_visible: true },
    });
    const h = handlers();
    render(app(BASE, h, <FailingTab status={404} />), {
      wrapper: QueryWrapper,
    });
    await waitFor(() => expect(get).toHaveBeenCalledTimes(1));
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(h.onSessionLost).not.toHaveBeenCalled();
    expect(h.onReplace).not.toHaveBeenCalled();
  });
});
```

If Base UI's `Toggle` exposes its state as `data-pressed` and not `aria-pressed` in this version, assert `toHaveAttribute("data-pressed")` instead. Check `SegmentedTabs.tsx` / the Base UI docs, and note the choice in the track.

Run: `cd WT && bun test src/components/client-lane/portal/PortalInsightsApp.test.tsx`
Expected: FAIL at import (`./PortalInsightsApp`).

- [ ] **Step 4: Implement the frame width and the shell**

In `src/components/client-lane/portal/PortalFrame.tsx`, replace the component with:

```tsx
export function PortalFrame({
  children,
  wide = false,
}: {
  children: ReactNode;
  /** Insights: the share dashboard's 1392px column (spec 2026-10-07 §4.2). */
  wide?: boolean;
}) {
  return (
    <div className="bg-app min-h-dvh font-geist [@media(max-width:768px)]:h-dvh [@media(max-width:768px)]:overflow-y-auto [@media(max-width:768px)]:overscroll-contain">
      <div
        className={`mx-auto flex w-full flex-col gap-6 px-4 pb-10 pt-4 sm:px-6 ${wide ? "max-w-[1392px]" : "max-w-[1120px]"}`}
      >
        {children}
      </div>
    </div>
  );
}
```

Both width classes appear literally, so Tailwind's scanner keeps them.

Create `src/components/client-lane/portal/PortalInsightsApp.tsx`:

```tsx
"use client";

import { useQueryClient } from "@tanstack/react-query";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  type ReactNode,
} from "react";

import { InsightSurfaceLayout } from "@/components/insight-surface/InsightSurfaceLayout";
import { PublicShareProvider } from "@/context/PublicShareContext";
import { trackPortalInsightsViewed } from "@/lib/analytics/client-lane-events";
import type { SurfaceTabKey } from "@/lib/insight-surface/tabs";
import {
  hasClientInsights,
  insightErrorAction,
  type PortalInsightInfo,
} from "@/lib/client-lane/portal/insightInfo";
import { portalErrorAction, portalHref } from "@/lib/client-lane/portal/shell";
import type { PortalBrand, PortalMe } from "@/lib/client-lane/portal/types";
import { publicApiError } from "@/lib/client-lane/publicApi";
import {
  isPortalInsightInfoKey,
  usePortalInsightInfo,
} from "@/services/client-portal";
import { portalInsightSurface } from "@/services/insightSurface";

import { PortalFrame } from "./PortalFrame";
import { PortalHeader } from "./PortalHeader";
import { PortalNav } from "./PortalNav";

/**
 * A signed-in client's Insights for one brand (spec 2026-10-07 §4.2): the
 * portal top bar with Insights selected, then the brand's share dashboard
 * — only the tabs ticked under Clients — read through the BFF.
 *
 * When access changes underneath it:
 * - an Insights call answering 401 → back to sign-in (`onSessionLost`);
 * - one answering 404 → re-read insight-info: gone (401/404) → sign-in,
 *   no tab left → Approvals, the tab closed → the layout moves to the
 *   first open one, still open (a missing report) → nothing.
 */
export function PortalInsightsApp({
  me,
  current,
  info: initialInfo,
  pathname,
  onNavigate,
  onReplace,
  onSessionLost = () => window.location.reload(),
  children,
}: {
  me: PortalMe;
  current: PortalBrand;
  info: PortalInsightInfo;
  pathname: string;
  onNavigate: (href: string) => void;
  onReplace: (href: string) => void;
  onSessionLost?: () => void;
  children: ReactNode;
}) {
  const workspaceSlug = current.workspace.slug;
  const brandSlug = current.brand.slug;
  const surface = useMemo(
    () => portalInsightSurface(workspaceSlug, brandSlug),
    [workspaceSlug, brandSlug]
  );
  const approvalsHref = portalHref(current);
  const infoQuery = usePortalInsightInfo(workspaceSlug, brandSlug, initialInfo);
  const info = infoQuery.data ?? initialInfo;

  const lost = useRef(false);
  const loseSession = useCallback(() => {
    if (lost.current) return;
    lost.current = true;
    onSessionLost();
  }, [onSessionLost]);

  const queryClient = useQueryClient();
  const { refetch } = infoQuery;
  useEffect(
    () =>
      queryClient.getQueryCache().subscribe((event) => {
        if (event.type !== "updated" || event.action.type !== "error") return;
        if (isPortalInsightInfoKey(event.query.queryKey)) return;
        const action = insightErrorAction(
          publicApiError(event.action.error).status
        );
        if (action === "sign_in") loseSession();
        else if (action === "recheck") void refetch();
      }),
    [queryClient, refetch, loseSession]
  );

  const infoStatus = infoQuery.error
    ? publicApiError(infoQuery.error).status
    : null;
  useEffect(() => {
    if (infoQuery.error && portalErrorAction(infoStatus) === "sign_in") {
      loseSession();
    }
  }, [infoQuery.error, infoStatus, loseSession]);

  const empty = !hasClientInsights(info);
  const left = useRef(false);
  useEffect(() => {
    if (!empty || left.current) return;
    left.current = true;
    onReplace(approvalsHref);
  }, [empty, approvalsHref, onReplace]);

  const lastViewed = useRef<SurfaceTabKey | null>(null);
  const onActiveTabChange = useCallback((tab: SurfaceTabKey) => {
    if (lastViewed.current === tab) return;
    lastViewed.current = tab;
    trackPortalInsightsViewed({ tab });
  }, []);

  return (
    <PortalFrame wide>
      <PortalHeader
        me={me}
        current={current}
        surface="portal"
        onNavigate={onNavigate}
        nav={
          <PortalNav
            waiting={current.waiting_on_you}
            active="insights"
            approvalsHref={approvalsHref}
            insightsHref={surface.basePath}
            onNavigate={onNavigate}
          />
        }
      />
      <PublicShareProvider
        slug={brandSlug}
        brandId={info.brandId}
        brandName={info.brandName}
        brandLogo={info.brandLogo}
        accessToken={null}
        ownedMediaTableView={info.ownedMediaTableView}
        surface={surface}
      >
        <InsightSurfaceLayout
          resolved={info.resolved}
          pathname={pathname}
          onNavigate={onNavigate}
          onReplace={onReplace}
          onActiveTabChange={onActiveTabChange}
        >
          {children}
        </InsightSurfaceLayout>
      </PublicShareProvider>
    </PortalFrame>
  );
}
```

If tsc says `event.action` is not on every event, narrow with `event.type === "updated"` first, as written. TanStack v5's `QueryCacheNotifyEvent` "updated" variant carries `action`.

- [ ] **Step 5: Run — PASS, then the mutations**

Run: `cd WT && bun test src/components/client-lane/portal/PortalInsightsApp.test.tsx`
Expected: `6 pass`. Apply each of the five mutations from the file header; each fails its named test. Restore. The tests do not depend on order: each has its own `QueryClient` and spies.

- [ ] **Step 6: The route seam, the shared page body, the route files**

Create `src/components/client-lane/portal/PortalInsightsRoute.tsx`:

```tsx
"use client";

import { usePathname, useRouter } from "next/navigation";
import type { ReactNode } from "react";

import type { PortalInsightInfo } from "@/lib/client-lane/portal/insightInfo";
import type { PortalBrand, PortalMe } from "@/lib/client-lane/portal/types";

import { PortalInsightsApp } from "./PortalInsightsApp";

/**
 * The portal Insights shell's router seam — the one portal file that reads
 * `next/navigation`, so `PortalInsightsApp` stays testable without an app
 * router. Rendered by the Insights layout, so it survives tab switches.
 */
export function PortalInsightsRoute({
  me,
  current,
  info,
  children,
}: {
  me: PortalMe;
  current: PortalBrand;
  info: PortalInsightInfo;
  children: ReactNode;
}) {
  const pathname = usePathname();
  const router = useRouter();
  return (
    <PortalInsightsApp
      me={me}
      current={current}
      info={info}
      pathname={pathname}
      onNavigate={(href) => router.push(href)}
      onReplace={(href) => router.replace(href)}
    >
      {children}
    </PortalInsightsApp>
  );
}
```

Create `src/components/insight-surface/InsightSurfaceRoutePage.tsx`:

```tsx
"use client";

import { useParams } from "next/navigation";

import { resolveInsightRoute } from "@/lib/insight-surface/routes";

import { InsightTabRouter } from "./InsightTabRouter";

/**
 * The page under an Insights `[[...tab]]` route — the client portal and
 * the client preview. The shell around it redirects paths no page
 * answers, so an unknown path renders nothing for the one frame before.
 */
export default function InsightSurfaceRoutePage() {
  const params = useParams<{ tab?: string[] }>();
  const route = resolveInsightRoute(params?.tab);
  return route ? <InsightTabRouter route={route} /> : null;
}
```

Create `src/app/s/[token]/[brand]/insights/[[...tab]]/page.tsx`:

```tsx
// The client portal's Insights pages (spec 2026-10-07 §4.2). Access and
// the shell live in ../layout.tsx; this is the shared page body.
export { default } from "@/components/insight-surface/InsightSurfaceRoutePage";
```

Create `src/app/s/[token]/[brand]/insights/layout.tsx`:

```tsx
import type { Metadata } from "next";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import type { ReactNode } from "react";

import { PortalExchangeGate } from "@/components/client-lane/portal/LaneExchange";
import { PortalInsightsRoute } from "@/components/client-lane/portal/PortalInsightsRoute";
import { PortalSignIn } from "@/components/client-lane/portal/PortalSignIn";
import {
  CLIENT_SESSION_COOKIE,
  LANE_COOKIE,
  LANE_FRESH_COOKIE,
  isClientSessionToken,
  shouldExchangeLane,
} from "@/lib/client-lane/cookie";
import { hasClientInsights } from "@/lib/client-lane/portal/insightInfo";
import {
  resolvePortalInsightInfoServer,
  resolvePortalMeServer,
} from "@/lib/client-lane/portal/server";
import { findPortalBrand, portalHref } from "@/lib/client-lane/portal/shell";

/**
 * The client portal's Insights — `/s/{workspace slug}/{brand slug}/insights`
 * (spec 2026-10-07 §4.2). Same access as the Approvals page: the session
 * cookie is read here only to forward to the api. Insights also needs at
 * least one tab open to clients; with none, the client goes back to
 * Approvals. `force-dynamic`: a revoked lane or an unticked tab must
 * never render from cache.
 */
export const dynamic = "force-dynamic";

// Generic on purpose: the title never confirms that a brand exists.
export const metadata: Metadata = {
  title: "Insights — frndOS",
  robots: { index: false, follow: false },
};

type Params = Promise<{ token: string; brand: string }>;

export default async function PortalInsightsLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Params;
}) {
  const { token: workspaceSlug, brand: brandSlug } = await params;
  const jar = await cookies();

  if (
    shouldExchangeLane({
      lane: jar.get(LANE_COOKIE)?.value,
      fresh: jar.get(LANE_FRESH_COOKIE)?.value,
    })
  ) {
    return (
      <PortalExchangeGate workspaceSlug={workspaceSlug} brandSlug={brandSlug} />
    );
  }

  const session = jar.get(CLIENT_SESSION_COOKIE)?.value;
  if (!isClientSessionToken(session)) {
    return <PortalSignIn workspaceSlug={workspaceSlug} brandSlug={brandSlug} />;
  }
  const me = await resolvePortalMeServer(session);
  const current = me ? findPortalBrand(me, workspaceSlug, brandSlug) : null;
  if (!me || !current) {
    return <PortalSignIn workspaceSlug={workspaceSlug} brandSlug={brandSlug} />;
  }

  const info = await resolvePortalInsightInfoServer(
    session,
    workspaceSlug,
    brandSlug
  );
  if (!info || !hasClientInsights(info)) redirect(portalHref(current));

  return (
    <PortalInsightsRoute me={me} current={current} info={info}>
      {children}
    </PortalInsightsRoute>
  );
}
```

`redirect()` returns `never`, so `info` is non-null after it.

- [ ] **Step 7: The report's creator row follows the client trim (I-5)**

The client payload has no `createdBy` (spec §3.4). `creatorLabel(undefined)` reads "—" next to an empty avatar.

In `src/components/brands/reports/ReportView.tsx`, wrap the existing creator `<span className="flex items-center gap-1.5">…{creatorName}</span></span>` and the `·` separator span right after it in:

```tsx
            {report.createdBy != null ? (
              <>
                {/* the two existing spans, unchanged */}
              </>
            ) : null}
```

Do not touch their classes. The Task 14 banned-class scan uses `git diff -w`, which ignores the re-indent, and the gate covers what this plan wrote. On the public share the payload still carries `createdBy`, so nothing changes there.

- [ ] **Step 8: Types, the build, the neighbours**

```bash
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-portal|PortalInsights|PortalFrame|insight-surface|s/\[token\]|ReportView"
cd WT && for f in src/components/client-lane/portal/PortalApp.test.tsx src/components/client-lane/portal/PortalSignIn.test.tsx src/components/client-lane/portal/LaneExchange.test.tsx src/lib/client-lane/tokenHygiene.publicPages.test.ts; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
cd WT && node ./node_modules/next/dist/bin/next build 2>&1 | /usr/bin/grep -E "/s/|Failed to compile|Module not found|Error:" | head -30
```

Expected:
- the count is ≤ baseline, with no new lines for the touched files;
- the neighbours match Task 0;
- the build's route table lists `ƒ /s/[token]/[brand]/insights/[[...tab]]` beside the existing `/s` routes, with no compile error.

- [ ] **Step 9: Smoke (only if the api branch already serves `insight-info`)**

With the api branch on :9191 and a client session (sign in through the portal):
- open `/s/{ws}/{brand}`: Insights appears only when a tab is ticked under Clients;
- click it: the strip shows only ticked tabs, and every call in the Network tab is `/s/api/portal/…/insight/…`, with no `X-Share-Token`.

Otherwise record "PENDING api" in the track; Task 14 repeats it.

- [ ] **Step 10: Lint, format, commit**

```bash
cd WT && F=(src/services/client-portal.ts src/services/client-portal.insights.test.ts src/components/client-lane/portal/PortalFrame.tsx src/components/client-lane/portal/PortalInsightsApp.tsx src/components/client-lane/portal/PortalInsightsApp.test.tsx src/components/client-lane/portal/PortalInsightsRoute.tsx src/components/insight-surface/InsightSurfaceRoutePage.tsx "src/app/s/[token]/[brand]/insights/layout.tsx" "src/app/s/[token]/[brand]/insights/[[...tab]]/page.tsx" src/components/brands/reports/ReportView.tsx); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" docs/tracks/client-portal.track.md && /usr/bin/git commit -F - <<'EOF'
feat(web): portal Insights at /s/{ws}/{brand}/insights

A server layout checks the session and that a tab is open to clients,
then keeps the portal header, nav and tab strip mounted while the
[[...tab]] body changes; reads go through the BFF. A 401 goes back to
sign-in; a 404 re-reads insight-info and goes to sign-in, Approvals or
the first open tab. Spec 2026-10-07 §4.2, I-1, I-3.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 10: The "Sample data" pill on Business and Listening (I-4)

**Files:**
- Create: `src/lib/insight-surface/sampleData.ts`
- Test: `src/lib/insight-surface/sampleData.test.ts` (create)
- Create: `src/components/insight-surface/SampleDataPill.tsx`
- Modify: `src/components/insight-surface/InsightSurfaceLayout.tsx`
- Test: `src/components/insight-surface/InsightSurfaceLayout.test.tsx` (append)

**Interfaces:**
- Consumes: `InsightAudience`, `SurfaceTabKey`; `useSocialListening(brandId).isDemoOn` (`@/hooks/useSocialListening`); `InsightHeaderBadge` (`@/components/brands/insight/InsightHeaderActions`); v2 `ItemRow.Tag`.
- Produces:

```ts
export function showsSampleData(input: {
  tab: SurfaceTabKey | null;
  audience: InsightAudience;
  listeningShowsFixtures: boolean; // useSocialListening(brandId).isDemoOn
}): boolean;
export function SampleDataPill(): JSX.Element; // "Sample data"
```

The pill shows only to clients and in the preview: spec §4.2 places it under the portal, and /share stays unchanged. It sits in the title row's badge slot, beside the Business profile chip.

- [ ] **Step 1: Resolve the Listening rule with Daffa (AskUserQuestion) — code and spec disagree**

The spec (I-4) says: "Business for every brand, Listening for non-demo brands."

The code says otherwise. Listening has no backend: `useSocialListening` serves fixtures ONLY for the five demo brands in `DEMO_BRAND_FIXTURE`. Every other brand renders the "connect a tool" empty state on the share page, and so in the portal. A literal reading puts "Sample data" above an empty state, and never above the demo fixtures, which are the illustrative numbers.

Ask:

> "Listening shows illustrative fixtures only for the five demo brands; real brands see the 'connect a tool' empty state. Where should the 'Sample data' pill go on Listening?"

Options:
- (b) **Wherever fixtures render (demo brands)** — recommended. It matches the spec's own reason ("wherever their data is illustrative"), and a demo brand shown to a client is exactly where numbers could be misread as real.
- (a) **Non-demo brands, as the spec says**: the pill sits above the empty state.
- (c) **Never on Listening** until it has real data.

Write the answer in the track. The code below is (b). For (a), the Listening line becomes `return !input.listeningShowsFixtures;`, and the two Listening test rows swap their expectations. For (c), it becomes `return false;`, and both Listening rows expect `false`.

- [ ] **Step 2: Write the failing rule test**

Create `src/lib/insight-surface/sampleData.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { showsSampleData } from "./sampleData";

// Named mutations (plan Task 10):
// - drop the `audience === "public"` guard → "never labels the public link"
// - return true for every tab → "labels nothing else"
// - flip the Listening line → both Listening rows

const client = { audience: "client" as const, listeningShowsFixtures: false };

describe("showsSampleData (spec 2026-10-07 I-4; Listening rule per Step 1)", () => {
  it("labels Business for every brand, for clients and the preview", () => {
    expect(showsSampleData({ ...client, tab: "business" })).toBe(true);
    expect(
      showsSampleData({ ...client, audience: "preview", tab: "business" })
    ).toBe(true);
  });

  it("labels Listening where its fixtures render", () => {
    expect(
      showsSampleData({
        ...client,
        tab: "social-listening",
        listeningShowsFixtures: true,
      })
    ).toBe(true);
  });

  it("does not label Listening's empty state", () => {
    expect(
      showsSampleData({
        ...client,
        tab: "social-listening",
        listeningShowsFixtures: false,
      })
    ).toBe(false);
  });

  it("labels nothing else", () => {
    for (const tab of ["overview", "paid-media", "signals"] as const) {
      expect(showsSampleData({ ...client, tab })).toBe(false);
    }
    expect(showsSampleData({ ...client, tab: null })).toBe(false);
  });

  it("never labels the public link", () => {
    expect(
      showsSampleData({
        tab: "business",
        audience: "public",
        listeningShowsFixtures: true,
      })
    ).toBe(false);
  });
});
```

Run: `cd WT && bun test src/lib/insight-surface/sampleData.test.ts`
Expected: FAIL at import.

- [ ] **Step 3: Implement the rule and the pill**

Create `src/lib/insight-surface/sampleData.ts`:

```ts
/**
 * The "Sample data" label (spec 2026-10-07 I-4): Business and Listening
 * can be opened for clients, and where their numbers are illustrative a
 * small pill says so, so a client never reads them as real. Business is
 * illustrative for every brand; Listening renders fixtures only for the
 * demo brands (`useSocialListening`) — the rule chosen in plan Task 10
 * Step 1. Only clients and the preview see it; the public link is
 * unchanged. Pure.
 */
import type { SurfaceTabKey } from "./tabs";
import type { InsightAudience } from "./types";

export function showsSampleData(input: {
  tab: SurfaceTabKey | null;
  audience: InsightAudience;
  listeningShowsFixtures: boolean;
}): boolean {
  if (input.audience === "public") return false;
  if (input.tab === "business") return true;
  if (input.tab === "social-listening") return input.listeningShowsFixtures;
  return false;
}
```

Create `src/components/insight-surface/SampleDataPill.tsx`:

```tsx
"use client";

import { ItemRow } from "@/components/frndos/v2";

/**
 * "Sample data" beside an Insights tab title (spec 2026-10-07 I-4) — the
 * quiet v2 tag. Its own file: the layout imports frndOS v1, and one file
 * never imports both.
 */
export function SampleDataPill() {
  return <ItemRow.Tag>Sample data</ItemRow.Tag>;
}
```

In `src/components/insight-surface/InsightSurfaceLayout.tsx`, add the imports:

```tsx
import { InsightHeaderBadge } from "@/components/brands/insight/InsightHeaderActions";
import { useSocialListening } from "@/hooks/useSocialListening";
import { showsSampleData } from "@/lib/insight-surface/sampleData";

import { SampleDataPill } from "./SampleDataPill";
```

Then:
- after `const activeId = active?.id ?? null;`, add (hooks stay above the early returns):

```tsx
  const { isDemoOn: listeningShowsFixtures } = useSocialListening(
    share?.brandId ?? ""
  );
```

- after `const showTitle = …;`, add:

```tsx
  const sample =
    showTitle &&
    showsSampleData({ tab: activeId, audience, listeningShowsFixtures });
```

- and render the pill right after the title row:

```tsx
      {showTitle ? <InsightPageHeaderRow title={title} /> : null}
      {sample ? (
        <InsightHeaderBadge>
          <SampleDataPill />
        </InsightHeaderBadge>
      ) : null}
      {children}
```

- [ ] **Step 4: Append the layout tests**

Check `wc -c src/components/insight-surface/InsightSurfaceLayout.test.tsx` (expect < 10 KB). Then append inside the file:

```tsx
// Named mutation (plan Task 10): render the pill whenever showTitle → "never labels the public link's Business".

describe("the Sample data pill (spec 2026-10-07 I-4)", () => {
  afterEach(() => cleanup());

  function renderTab(
    pathname: string,
    opts: { brandId: string; portal: boolean; open: ResolvedTabMap }
  ) {
    render(
      <PublicShareProvider
        slug="frndglow"
        brandId={opts.brandId}
        brandName="frndGlow"
        brandLogo={null}
        accessToken={null}
        surface={opts.portal ? portalInsightSurface("fcn", "frndglow") : undefined}
      >
        <InsightSurfaceLayout
          resolved={opts.open}
          pathname={pathname}
          onNavigate={vi.fn()}
          onReplace={vi.fn()}
        >
          <p>tab content</p>
        </InsightSurfaceLayout>
      </PublicShareProvider>
    );
  }

  const open: ResolvedTabMap = {
    business: { label: "Business", is_visible: true },
    "social-listening": { label: "Listening", is_visible: true },
  };

  it("labels Business for a client", async () => {
    renderTab(`${BASE}/business`, { brandId: "01brand", portal: true, open });
    expect(await body().findByText("Sample data")).toBeInTheDocument();
  });

  it("labels a demo brand's Listening for a client", async () => {
    renderTab(`${BASE}/social-listening`, {
      brandId: "01kqyj3q36zxwrqttyhqfmbj32", // frndGlow demo fixture
      portal: true,
      open,
    });
    expect(await body().findByText("Sample data")).toBeInTheDocument();
  });

  it("never labels the public link's Business", async () => {
    renderTab("/share/brand/frndglow/business", {
      brandId: "01brand",
      portal: false,
      open,
    });
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(body().queryByText("Sample data")).toBeNull();
  });
});
```

The demo ULID comes from `DEMO_BRAND_FIXTURE` in `src/hooks/useSocialListening.ts`. Copy it from there, not from this plan. If Step 1 chose (a) or (c), change the Listening test accordingly.

- [ ] **Step 5: Run — PASS, then the mutations**

```bash
cd WT && bun test src/lib/insight-surface/sampleData.test.ts && bun test src/components/insight-surface/InsightSurfaceLayout.test.tsx && bun test src/components/client-lane/portal/PortalInsightsApp.test.tsx
```

Expected: all green. Apply every mutation from both files' headers; each fails its named test. Restore.

- [ ] **Step 6: Lint, format, commit**

```bash
cd WT && F=(src/lib/insight-surface/sampleData.ts src/lib/insight-surface/sampleData.test.ts src/components/insight-surface/SampleDataPill.tsx src/components/insight-surface/InsightSurfaceLayout.tsx src/components/insight-surface/InsightSurfaceLayout.test.tsx); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" docs/tracks/client-portal.track.md && /usr/bin/git commit -F - <<'EOF'
feat(web): "Sample data" pill on Business and Listening for clients

Business is illustrative for every brand; Listening where its fixtures
render (rule confirmed with Daffa — see the track). Clients and the
preview only; the public link is unchanged. Spec 2026-10-07 I-4.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 11: The "Clients" column in Brand Settings → Insights Tabs (I-2, §4.3)

**Files:**
- Modify: `src/services/insightsTabSettings.ts`
- Modify: `src/lib/insightsTabResolution.ts` (hand-format; never prettier)
- Create: `src/lib/insight-surface/clientVisibility.ts`
- Test: `src/lib/insight-surface/clientVisibility.test.ts` (create)
- Create: `src/components/brands/settings/insightsTabs/ClientVisibleCheckbox.tsx`
- Modify: `src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.tsx`
- Test: `src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx` (create)
- Modify: `src/components/brands/settings/sections/InsightsTabSettingsSection.tsx`
- Modify: `src/app/(dashboard)/brands/[id]/settings/insights-tabs/page.tsx` (hand-format)

**Interfaces:**
- Consumes: `isClientEligibleTab`, `isSurfaceTabKey`, `SurfaceTabKey` (Tasks 4–5); `trackInsightsTabClientVisibilityChanged` (Task 7); v2 `Checkbox` (`checked`, `onChange(next)`, `disabled`, `size`, `label` = its accessible name); `useClientLaneEnabled` (`@/lib/featureFlags`, in the route file only).
- Produces:

```ts
// services/insightsTabSettings.ts + lib/insightsTabResolution.ts
//   TabOverridePayload / TabOverride gain `client_visible?: boolean` (assumed wire key; absent = false)
// lib/insight-surface/clientVisibility.ts
export function clientVisibilityChanges(
  before: OverridesMap, after: OverridesMap
): Array<{ tab: SurfaceTabKey; visible: boolean }>;
// ClientVisibleCheckbox
export function ClientVisibleCheckbox(props: {
  tabLabel: string; checked: boolean; onChange: (next: boolean) => void; disabled?: boolean;
}): JSX.Element; // accessible name "Show {tabLabel} to clients"
// InsightsTabSettingsForm: new optional prop `clientsColumn?: boolean` (honoured in brand scope only)
// BrandInsightsTabSettingsSection: new optional prop `clientsColumn?: boolean`
```

Rules this task pins:
- The Clients tick is independent of the "Visible" toggle (I-2). It is offered on the nine surface tabs only, never on `dashboard`, which has no read-only page.
- Reset and Reset all touch the label and visibility only; they keep the tick.
- A save sends `client_visible` for the surface tabs only, and only in brand scope. The workspace endpoint never sees the key (assumed contract (b)).
- `insights_tab_client_visibility_changed` fires after the save succeeds, once per tab whose saved tick changed. It never fires on the tick itself.

- [ ] **Step 1: Write the failing pure test**

Create `src/lib/insight-surface/clientVisibility.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { clientVisibilityChanges } from "./clientVisibility";

// Named mutations (plan Task 11):
// - read a missing `before` row as true → "reports only real changes" (overview appears)
// - drop the isSurfaceTabKey guard → "ignores tabs clients never see"

describe("clientVisibilityChanges (spec 2026-10-07 §4.5)", () => {
  it("reports only real changes, in the saved order", () => {
    expect(
      clientVisibilityChanges(
        {
          business: { label: null, is_visible: null, client_visible: true },
          atl: { label: null, is_visible: null },
        },
        {
          business: { label: null, is_visible: null, client_visible: false },
          atl: { label: null, is_visible: null, client_visible: true },
          overview: { label: null, is_visible: null, client_visible: false },
          signals: { label: null, is_visible: null },
        }
      )
    ).toEqual([
      { tab: "business", visible: false },
      { tab: "atl", visible: true },
    ]);
  });

  it("ignores tabs clients never see", () => {
    expect(
      clientVisibilityChanges(
        {},
        { dashboard: { label: null, is_visible: null, client_visible: true } }
      )
    ).toEqual([]);
  });
});
```

Run: `cd WT && bun test src/lib/insight-surface/clientVisibility.test.ts`
Expected: FAIL at import.

- [ ] **Step 2: Types and the rule**

In `src/services/insightsTabSettings.ts`, in `TabOverridePayload`, after `is_visible: boolean | null;`:

```ts
  /**
   * Brand scope only — the tab is open to clients in their portal (spec
   * 2026-10-07 I-2). Absent = false. Never sent for workspace defaults.
   */
  client_visible?: boolean;
```

In `src/lib/insightsTabResolution.ts`, in `TabOverride`, after `is_visible: boolean | null;`, hand-format this and never run prettier on the file:

```ts
  /** Brand scope only: open to clients (spec 2026-10-07 I-2). Absent = false. */
  client_visible?: boolean;
```

Create `src/lib/insight-surface/clientVisibility.ts`:

```ts
/**
 * Which tabs' Clients tick a saved Insights-tab settings change actually
 * moved (spec 2026-10-07 §4.5) — one analytics event each, after the save
 * succeeds. A missing row or key reads as off (the api's default). Pure.
 */
import type { OverridesMap, TabOverride } from "@/lib/insightsTabResolution";

import { isSurfaceTabKey, type SurfaceTabKey } from "./tabs";

export function clientVisibilityChanges(
  before: OverridesMap,
  after: OverridesMap
): Array<{ tab: SurfaceTabKey; visible: boolean }> {
  const changes: Array<{ tab: SurfaceTabKey; visible: boolean }> = [];
  for (const [key, row] of Object.entries(after) as Array<
    [string, TabOverride | undefined]
  >) {
    if (!isSurfaceTabKey(key) || row?.client_visible === undefined) continue;
    const was = before[key]?.client_visible === true;
    if (row.client_visible !== was) {
      changes.push({ tab: key, visible: row.client_visible });
    }
  }
  return changes;
}
```

Run: `cd WT && bun test src/lib/insight-surface/clientVisibility.test.ts`
Expected: `2 pass`. Apply both mutations; each fails its named test. Restore.

- [ ] **Step 3: Write the failing form test**

Create `src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { GLOBAL_INSIGHTS_TABS } from "@/constants/insightsTabs";
import {
  resolvedMapToTabs,
  type OverridesMap,
} from "@/lib/insightsTabResolution";

import { InsightsTabSettingsForm } from "./InsightsTabSettingsForm";

// Named mutations (plan Task 11):
// - render the tick on every row → "offers a Clients tick per surface tab, never for Dashboard"
// - send client_visible on every row → "saves the ticks…" (the dashboard assertion)
// - resetAll without `...rows[tab.id]` → "keeps a tick through Reset all"
// - ignore `scope` (show the column on workspace) → "has no Clients column for workspace defaults"

const body = () => within(document.body);
const PARENT = resolvedMapToTabs(GLOBAL_INSIGHTS_TABS, undefined);

type Meta = { isDirty: boolean; isValid: boolean; save: () => void };

function renderForm(
  props: Partial<Parameters<typeof InsightsTabSettingsForm>[0]> = {}
) {
  const onSave = vi.fn();
  const meta: { current: Meta | null } = { current: null };
  render(
    <InsightsTabSettingsForm
      scope="brand"
      parentResolvedTabs={PARENT}
      currentOverrides={{
        "paid-media": { label: null, is_visible: null, client_visible: true },
      }}
      isSaving={false}
      onSave={onSave}
      onMetaChange={(m) => {
        meta.current = m;
      }}
      clientsColumn
      {...props}
    />
  );
  return { onSave, meta };
}

describe("Insights Tabs → Clients (spec 2026-10-07 I-2, §4.3)", () => {
  beforeEach(() => vi.restoreAllMocks());
  afterEach(() => cleanup());

  it("offers a Clients tick per surface tab, never for Dashboard", () => {
    renderForm();
    expect(
      body().getByRole("checkbox", { name: "Show Ads to clients" })
    ).toBeChecked();
    expect(
      body().getByRole("checkbox", { name: "Show Business to clients" })
    ).not.toBeChecked();
    expect(
      body().queryByRole("checkbox", { name: "Show Dashboard to clients" })
    ).toBeNull();
    expect(body().getAllByRole("checkbox")).toHaveLength(9);
  });

  it("saves the ticks with the overrides, and only on surface tabs", async () => {
    const user = userEvent.setup();
    const { onSave, meta } = renderForm();
    await user.click(
      body().getByRole("checkbox", { name: "Show Business to clients" })
    );
    expect(meta.current?.isDirty).toBe(true);
    act(() => meta.current?.save());
    const saved = onSave.mock.calls[0][0] as OverridesMap;
    expect(saved.business?.client_visible).toBe(true);
    expect(saved["paid-media"]?.client_visible).toBe(true);
    expect(saved.overview?.client_visible).toBe(false);
    expect(Object.keys(saved.dashboard ?? {})).not.toContain("client_visible");
  });

  it("keeps a tick through Reset all", async () => {
    const user = userEvent.setup();
    const { onSave, meta } = renderForm({
      currentOverrides: {
        atl: { label: "TV", is_visible: null, client_visible: true },
      },
    });
    await user.click(body().getByRole("button", { name: "Reset all" }));
    act(() => meta.current?.save());
    const saved = onSave.mock.calls[0][0] as OverridesMap;
    expect(saved.atl).toEqual({
      label: null,
      is_visible: null,
      client_visible: true,
    });
  });

  it("has no Clients column for workspace defaults", () => {
    renderForm({ scope: "workspace", currentOverrides: {} });
    expect(body().queryAllByRole("checkbox")).toHaveLength(0);
    expect(body().queryByText("Clients")).toBeNull();
  });
});
```

Run: `cd WT && bun test src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx`
Expected: the first three FAIL (no checkboxes). The workspace test passes already: it is the guard against over-showing.

- [ ] **Step 4: The checkbox wrapper and the form**

Create `src/components/brands/settings/insightsTabs/ClientVisibleCheckbox.tsx`:

```tsx
"use client";

import { Checkbox } from "@/components/frndos/v2";

/**
 * The Clients tick of one Insights tab (spec 2026-10-07 §4.3) — the v2
 * Checkbox in its own file: the settings form is frndOS v1, and one file
 * never imports both.
 */
export function ClientVisibleCheckbox({
  tabLabel,
  checked,
  onChange,
  disabled = false,
}: {
  tabLabel: string;
  checked: boolean;
  onChange: (next: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <Checkbox
      size="sm"
      checked={checked}
      onChange={onChange}
      disabled={disabled}
      label={`Show ${tabLabel} to clients`}
    />
  );
}
```

In `src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.tsx`:

(a) Imports. Add:

```tsx
import { isClientEligibleTab } from "@/lib/insight-surface/tabs";

import { ClientVisibleCheckbox } from "./ClientVisibleCheckbox";
```

(b) Props: in `InsightsTabSettingsFormProps`, after `readOnly?: boolean;`:

```tsx
  /**
   * Brand scope: show the per-tab Clients tick (spec 2026-10-07 I-2),
   * behind `show-client-lane`. Ignored for workspace defaults.
   */
  clientsColumn?: boolean;
```

and destructure `clientsColumn = false,` beside `readOnly = false,`. Right after the destructure, add:

```tsx
  const showClients = scope === "brand" && clientsColumn;
```

(c) `RowState`: after `is_visible: boolean | null;`, add `/** Open to clients (brand scope). */ client_visible: boolean;`. In `overridesToRowState`, add `client_visible: row?.client_visible === true,` to the row object.

(d) Dirty tracking: in `validRows`, after `const visibilityChanged = …;`, add

```tsx
      const clientChanged =
        showClients &&
        r.client_visible !== (base?.client_visible ?? false);
```

and change `if (labelChanged || visibilityChanged) anyDirty = true;` to `if (labelChanged || visibilityChanged || clientChanged) anyDirty = true;`.

Add `showClients` to that `useMemo`'s dependency array.

(e) Save: in `handleSaveRef.current`, replace `overrides[tab.id] = override;` with

```tsx
      if (showClients && isClientEligibleTab(tab.id)) {
        override.client_visible = r.client_visible;
      }
      overrides[tab.id] = override;
```

(f) Reset all keeps the tick: in `resetAll`, replace `next[tab.id] = { label: "", is_visible: null, error: null };` with `next[tab.id] = { ...rows[tab.id], label: "", is_visible: null, error: null };`. `resetRow` already merges through `setRow`.

(g) Helper line: under the existing `<p className="max-w-2xl …">{helperText}</p>`, add

```tsx
          {showClients ? (
            <p className="max-w-2xl font-geist text-textSm text-text-inverse-subtle">
              Tick Clients to open a tab in your clients&apos; portal.
            </p>
          ) : null}
```

(h) The tick: in `visibilityBlock`, inside `<div className="flex items-center gap-4">` and before the `<label …>` that holds "Visible", add

```tsx
                {showClients && isClientEligibleTab(tab.id) ? (
                  <div className="flex select-none items-center gap-2">
                    <span
                      aria-hidden
                      className="hidden font-geist text-textSm text-text-inverse-subtle sm:inline"
                    >
                      Clients
                    </span>
                    <ClientVisibleCheckbox
                      tabLabel={globalLabel ?? tab.label}
                      checked={row.client_visible}
                      onChange={(checked) =>
                        setRow(tab.id, { client_visible: checked })
                      }
                      disabled={readOnly}
                    />
                  </div>
                ) : null}
```

A `div`, not a `label`: the Base UI checkbox is a button carrying its own name. Wrapping it in a label would double-activate it.

- [ ] **Step 5: The section and the page**

In `src/components/brands/settings/sections/InsightsTabSettingsSection.tsx`:
- add the imports:

```tsx
import { trackInsightsTabClientVisibilityChanged } from "@/lib/analytics/brand-settings-events";
import { clientVisibilityChanges } from "@/lib/insight-surface/clientVisibility";
```

- in `BrandSectionProps`, add `/** Per-tab Clients tick (spec 2026-10-07 I-2), behind show-client-lane. */ clientsColumn?: boolean;`, and destructure `clientsColumn = false,`;
- in the brand section's `<InsightsTabSettingsForm …>`, add `clientsColumn={clientsColumn}` and replace `onSave={(overrides) => mutation.mutate({ overrides })}` with

```tsx
      onSave={(overrides) =>
        mutation.mutate(
          { overrides },
          {
            // One event per tab whose Clients tick the save moved (§4.5).
            onSuccess: () => {
              for (const change of clientVisibilityChanges(
                brandOverrides,
                overrides
              )) {
                trackInsightsTabClientVisibilityChanged(change);
              }
            },
          }
        )
      }
```

  `mutation.mutate`'s `overrides` type is `UpdateInsightsTabSettingsBody["overrides"]`. `TabOverridePayload` and `TabOverride` now both carry `client_visible?`, so they stay assignable.

The workspace section is untouched.

In `src/app/(dashboard)/brands/[id]/settings/insights-tabs/page.tsx` (hand-format):
- add `import { useClientLaneEnabled } from "@/lib/featureFlags";`;
- add `const clientLane = useClientLaneEnabled();` beside the permission hooks, above the early return;
- pass `clientsColumn={clientLane}` to `<BrandInsightsTabSettingsSection …>`.

- [ ] **Step 6: Run — PASS, the mutations, the neighbours**

```bash
cd WT && for f in src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx src/lib/insight-surface/clientVisibility.test.ts src/constants/insightsTabs.test.ts src/components/frndos/v2/Checkbox.test.tsx; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: green, and the neighbours match Task 0. Apply the four form mutations; each fails its named test. Restore.

- [ ] **Step 7: Lint, format, commit**

```bash
cd WT && F=(src/services/insightsTabSettings.ts src/lib/insight-surface/clientVisibility.ts src/lib/insight-surface/clientVisibility.test.ts src/components/brands/settings/insightsTabs/ClientVisibleCheckbox.tsx src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.tsx src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx src/components/brands/settings/sections/InsightsTabSettingsSection.tsx); H=(src/lib/insightsTabResolution.ts "src/app/(dashboard)/brands/[id]/settings/insights-tabs/page.tsx"); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" "${H[@]}" && /usr/bin/git add "${F[@]}" "${H[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): Insights Tabs — a Clients tick per tab, default off

Brand scope only, behind show-client-lane: a v2 Checkbox per surface tab
(never Dashboard), independent of Visible, kept through Reset. Saved as
client_visible on the brand's overrides; one
insights_tab_client_visibility_changed per tab the save moved.
Spec 2026-10-07 I-2, §4.3, §4.5.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 12: Preview as client (§4.3)

**Blocking assumption:** the agency-session preview endpoints (`v1/brands/{brand}/client-preview/insight-info` and `…/insight/*`; see "API contract assumed"). Before Step 1, check the api plan's contract section.
- If it names other paths, change `previewInsightSurface`'s prefix and `fetchClientPreviewInfo`'s path, plus their tests (Task 2's preview test, and Step 1 below), to those paths.
- If it declines a preview group, STOP this task and record "Preview as client blocked on api" in the track.

**Files:**
- Modify: `src/services/insightSurface.ts` (`clientPreviewInfoKey`, `fetchClientPreviewInfo`)
- Create: `src/components/insight-surface/InsightClientPreview.tsx`
- Test: `src/components/insight-surface/InsightClientPreview.test.tsx` (create)
- Create: `src/app/(dashboard)/brands/[id]/settings/insights-tabs/preview/layout.tsx`
- Create: `src/app/(dashboard)/brands/[id]/settings/insights-tabs/preview/[[...tab]]/page.tsx`
- Modify: `src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.tsx` (the button)
- Test: `src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx` (append)
- Modify: `src/components/brands/settings/sections/InsightsTabSettingsSection.tsx`, `src/app/(dashboard)/brands/[id]/settings/insights-tabs/page.tsx`

**Interfaces:**
- Consumes: `previewInsightSurface` (Task 2), `normaliseInsightInfo`, `hasClientInsights` (Task 8), `InsightSurfaceLayout` (Task 5), `InsightSurfaceRoutePage` (Task 9), `trackInsightsPreviewAsClientOpened` (Task 7), v2 `Button`.
- Produces:

```ts
// services/insightSurface.ts (added)
export const clientPreviewInfoKey: (brandId: string) => readonly ["client-preview-info", string];
export function fetchClientPreviewInfo(brandId: string): Promise<PortalInsightInfo>; // axiosInstance
// InsightClientPreview
export function InsightClientPreview(props: {
  brandId: string; pathname: string;
  onNavigate: (href: string) => void; onReplace: (href: string) => void; onExit: () => void;
  children: ReactNode;
}): JSX.Element;
// InsightsTabSettingsForm / BrandInsightsTabSettingsSection: new optional prop `onPreviewAsClient?: () => void`
```

The preview renders inside the settings shell at `/brands/{id}/settings/insights-tabs/preview/[[...tab]]`: spec §4.3 says "a read-only preview mode on the settings page". It reads what is SAVED, so the button is disabled while the form has unsaved changes. `BrandSettingsSaveBarStateRoot` already resets the save bar on every pathname change, so the preview inherits no stale save bar.

- [ ] **Step 1: Write the failing preview test**

Create `src/components/insight-surface/InsightClientPreview.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, render, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState, type ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import axiosInstance from "@/services/axios";

import { InsightClientPreview } from "./InsightClientPreview";

// Named mutations (plan Task 12):
// - build the share surface instead of previewInsightSurface → "shows what clients see…" (the GET path)
// - render the layout even with no open tab → "says when no tab is open to clients"

const body = () => within(document.body);
const BASE = "/brands/b1/settings/insights-tabs/preview";

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function infoAnswers(resolved: Record<string, unknown>) {
  return vi.spyOn(axiosInstance, "get").mockResolvedValue({
    data: {
      data: {
        brand_id: "01brand",
        brand_name: "frndGlow",
        insights_tab_settings: { resolved },
      },
    },
  } as never);
}

function renderPreview() {
  const onExit = vi.fn();
  render(
    <InsightClientPreview
      brandId="b1"
      pathname={BASE}
      onNavigate={vi.fn()}
      onReplace={vi.fn()}
      onExit={onExit}
    >
      <p>tab content</p>
    </InsightClientPreview>,
    { wrapper: QueryWrapper }
  );
  return { onExit };
}

describe("InsightClientPreview (spec 2026-10-07 §4.3)", () => {
  beforeEach(() => vi.restoreAllMocks());
  afterEach(() => cleanup());

  it("shows what clients see, read through the agency session", async () => {
    const user = userEvent.setup();
    const get = infoAnswers({
      overview: { label: "Overview", is_visible: true },
      atl: { label: "ATL", is_visible: true },
      business: { label: "Business", is_visible: false },
    });
    const { onExit } = renderPreview();
    expect(
      await body().findByText("Previewing what clients see")
    ).toBeInTheDocument();
    expect(get).toHaveBeenCalledWith(
      "v1/brands/b1/client-preview/insight-info"
    );
    expect(body().getByRole("button", { name: "ATL" })).toBeInTheDocument();
    expect(body().queryByRole("button", { name: "Business" })).toBeNull();
    expect(body().getByText("tab content")).toBeInTheDocument();
    await user.click(body().getByRole("button", { name: "Back to settings" }));
    expect(onExit).toHaveBeenCalled();
  });

  it("says when no tab is open to clients", async () => {
    infoAnswers({ overview: { label: "Overview", is_visible: false } });
    renderPreview();
    expect(
      await body().findByText("No tabs are open to clients yet.")
    ).toBeInTheDocument();
    expect(body().queryByText("tab content")).toBeNull();
  });

  it("says when the preview cannot load", async () => {
    vi.spyOn(axiosInstance, "get").mockRejectedValue(new Error("down"));
    renderPreview();
    expect(await body().findByRole("alert")).toHaveTextContent(
      "Couldn't load the preview."
    );
  });
});
```

Run: `cd WT && bun test src/components/insight-surface/InsightClientPreview.test.tsx`
Expected: FAIL at import.

- [ ] **Step 2: Implement the service read and the component**

Append to `src/services/insightSurface.ts`:
- add the import `import { normaliseInsightInfo, type PortalInsightInfo } from "@/lib/client-lane/portal/insightInfo";` at the top;
- append:

```ts
export const clientPreviewInfoKey = (brandId: string) =>
  ["client-preview-info", brandId] as const;

/** The client-visible tabs, read as the signed-in agency user (spec §4.3; assumed endpoint). */
export async function fetchClientPreviewInfo(
  brandId: string
): Promise<PortalInsightInfo> {
  const res = await axiosInstance.get(
    `v1/brands/${brandId}/client-preview/insight-info`
  );
  const info = normaliseInsightInfo(res.data);
  if (!info) throw new Error("client-preview insight-info without a brand");
  return info;
}
```

Create `src/components/insight-surface/InsightClientPreview.tsx`:

```tsx
"use client";

import { useQuery } from "@tanstack/react-query";
import { useMemo, type ReactNode } from "react";

import { Button } from "@/components/frndos/v2";
import { PublicShareProvider } from "@/context/PublicShareContext";
import { hasClientInsights } from "@/lib/client-lane/portal/insightInfo";
import {
  clientPreviewInfoKey,
  fetchClientPreviewInfo,
  previewInsightSurface,
} from "@/services/insightSurface";

import { InsightSurfaceLayout } from "./InsightSurfaceLayout";

/**
 * Brand Settings → Insights Tabs → "Preview as client" (spec 2026-10-07
 * §4.3): the portal's Insights, read-only, through the agency's own
 * session — only the tabs ticked under Clients, as SAVED. No client lane
 * needed.
 */
export function InsightClientPreview({
  brandId,
  pathname,
  onNavigate,
  onReplace,
  onExit,
  children,
}: {
  brandId: string;
  pathname: string;
  onNavigate: (href: string) => void;
  onReplace: (href: string) => void;
  onExit: () => void;
  children: ReactNode;
}) {
  const surface = useMemo(() => previewInsightSurface(brandId), [brandId]);
  const info = useQuery({
    queryKey: clientPreviewInfoKey(brandId),
    queryFn: () => fetchClientPreviewInfo(brandId),
    retry: false,
    staleTime: 0,
  });

  let content: ReactNode;
  if (info.isPending) {
    content = (
      <p
        role="status"
        className="font-geist text-textSm text-text-inverse-subtle"
      >
        Loading the preview…
      </p>
    );
  } else if (info.isError) {
    content = (
      <p
        role="alert"
        className="font-geist text-textSm text-text-inverse-subtle"
      >
        {"Couldn't load the preview."}
      </p>
    );
  } else if (!hasClientInsights(info.data)) {
    content = (
      <div className="flex flex-col items-center gap-1 py-10 text-center">
        <p className="font-geist text-textSmMedium text-text-inverse">
          No tabs are open to clients yet.
        </p>
        <p className="font-geist text-textSm text-text-inverse-subtle">
          Tick Clients on a tab, then save.
        </p>
      </div>
    );
  } else {
    content = (
      <PublicShareProvider
        slug={brandId}
        brandId={info.data.brandId}
        brandName={info.data.brandName}
        brandLogo={info.data.brandLogo}
        accessToken={null}
        ownedMediaTableView={info.data.ownedMediaTableView}
        surface={surface}
      >
        <InsightSurfaceLayout
          resolved={info.data.resolved}
          pathname={pathname}
          onNavigate={onNavigate}
          onReplace={onReplace}
        >
          {children}
        </InsightSurfaceLayout>
      </PublicShareProvider>
    );
  }

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-border-default bg-white/5 px-4 py-3">
        <div className="flex min-w-0 flex-col gap-0.5">
          <p className="font-geist text-textSmMedium text-text-inverse">
            Previewing what clients see
          </p>
          <p className="font-geist text-textXs text-text-inverse-subtle">
            Only the tabs ticked under Clients appear, read-only.
          </p>
        </div>
        <Button variant="secondary" size="small" onClick={onExit}>
          Back to settings
        </Button>
      </div>
      {content}
    </div>
  );
}
```

Run: `cd WT && bun test src/components/insight-surface/InsightClientPreview.test.tsx`
Expected: `3 pass`. Apply both mutations; each fails its named test. Restore.

- [ ] **Step 3: The preview route**

Create `src/app/(dashboard)/brands/[id]/settings/insights-tabs/preview/layout.tsx`:

```tsx
"use client";

import { useEffect, useRef, type ReactNode } from "react";
import { useParams, usePathname, useRouter } from "next/navigation";

import { InsightClientPreview } from "@/components/insight-surface/InsightClientPreview";
import { usePermissions } from "@/hooks/usePermissions";
import { useClientLaneEnabled } from "@/lib/featureFlags";

/**
 * Brand Settings → Insights Tabs → Preview as client (spec 2026-10-07
 * §4.3). Same read permission as the settings page; behind
 * show-client-lane. A layout, so the banner and the tab strip stay
 * mounted while the [[...tab]] body changes.
 */
export default function InsightsClientPreviewLayout({
  children,
}: {
  children: ReactNode;
}) {
  const brandId = useParams().id as string;
  const pathname = usePathname();
  const router = useRouter();
  const clientLane = useClientLaneEnabled();
  const { isPermissionsLoaded, canReadForBrand } = usePermissions();

  const loaded = isPermissionsLoaded();
  const hasAccess = canReadForBrand("brand.settings", brandId);
  const redirected = useRef(false);

  useEffect(() => {
    if (!loaded || hasAccess || redirected.current) return;
    redirected.current = true;
    router.replace(`/brands/${brandId}/settings/general`);
  }, [loaded, hasAccess, router, brandId]);

  if (!loaded || !hasAccess || !clientLane) return null;

  return (
    <InsightClientPreview
      brandId={brandId}
      pathname={pathname}
      onNavigate={(href) => router.push(href)}
      onReplace={(href) => router.replace(href)}
      onExit={() => router.push(`/brands/${brandId}/settings/insights-tabs`)}
    >
      {children}
    </InsightClientPreview>
  );
}
```

Create `src/app/(dashboard)/brands/[id]/settings/insights-tabs/preview/[[...tab]]/page.tsx`:

```tsx
// Preview as client — the shared Insights page body (spec 2026-10-07 §4.3).
export { default } from "@/components/insight-surface/InsightSurfaceRoutePage";
```

- [ ] **Step 4: The button — failing tests first**

Append to `InsightsTabSettingsForm.clients.test.tsx`. Check `wc -c` first (expect < 12 KB). Add `import posthog from "posthog-js";` to its imports, and add:

```tsx
// Named mutations (plan Task 12):
// - drop `disabled={validRows.isDirty}` → "holds the preview while changes are unsaved"
// - drop the trackInsightsPreviewAsClientOpened call → "opens the preview and counts it"

describe("Preview as client (spec 2026-10-07 §4.3)", () => {
  beforeEach(() => vi.restoreAllMocks());
  afterEach(() => cleanup());

  it("opens the preview and counts it", async () => {
    const user = userEvent.setup();
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const onPreviewAsClient = vi.fn();
    renderForm({ onPreviewAsClient });
    await user.click(body().getByRole("button", { name: "Preview as client" }));
    expect(onPreviewAsClient).toHaveBeenCalledTimes(1);
    expect(capture).toHaveBeenCalledWith(
      "insights_preview_as_client_opened",
      expect.any(Object)
    );
  });

  it("holds the preview while changes are unsaved", async () => {
    const user = userEvent.setup();
    renderForm({ onPreviewAsClient: vi.fn() });
    await user.click(
      body().getByRole("checkbox", { name: "Show Business to clients" })
    );
    expect(
      body().getByRole("button", { name: "Preview as client" })
    ).toBeDisabled();
    expect(
      body().getByText("Save your changes to preview them.")
    ).toBeInTheDocument();
  });

  it("offers no preview without the Clients column", () => {
    renderForm({ clientsColumn: false, onPreviewAsClient: vi.fn() });
    expect(
      body().queryByRole("button", { name: "Preview as client" })
    ).toBeNull();
  });
});
```

Run the file. Expected: the first two FAIL (no button). The third passes already.

- [ ] **Step 5: Implement the button and wire it**

In `InsightsTabSettingsForm.tsx`:
- add `import { trackInsightsPreviewAsClientOpened } from "@/lib/analytics/brand-settings-events";`;
- add the prop

```tsx
  /** Brand scope + Clients column: open the client preview (spec §4.3). */
  onPreviewAsClient?: () => void;
```

  and destructure it;
- replace the header's

```tsx
        {!readOnly && (
          <Button
            variant="secondary"
            size="small"
            onClick={resetAll}
            disabled={!hasAnyOverride || isSaving}
          >
            Reset all
          </Button>
        )}
```

  with

```tsx
        <div className="flex shrink-0 items-start gap-2">
          {showClients && onPreviewAsClient ? (
            <div className="flex flex-col items-end gap-1">
              <Button
                variant="secondary"
                size="small"
                onClick={() => {
                  trackInsightsPreviewAsClientOpened();
                  onPreviewAsClient();
                }}
                disabled={validRows.isDirty}
              >
                Preview as client
              </Button>
              {validRows.isDirty ? (
                <span className="font-geist text-textXs text-text-inverse-subtlest">
                  Save your changes to preview them.
                </span>
              ) : null}
            </div>
          ) : null}
          {!readOnly && (
            <Button
              variant="secondary"
              size="small"
              onClick={resetAll}
              disabled={!hasAnyOverride || isSaving}
            >
              Reset all
            </Button>
          )}
        </div>
```

In `InsightsTabSettingsSection.tsx`, add `onPreviewAsClient?: () => void;` to `BrandSectionProps`, destructure it, and pass `onPreviewAsClient={onPreviewAsClient}` to the brand form.

In `insights-tabs/page.tsx` (hand-format), pass:

```tsx
        onPreviewAsClient={
          clientLane
            ? () => router.push(`/brands/${brandId}/settings/insights-tabs/preview`)
            : undefined
        }
```

- [ ] **Step 6: Run — PASS, the mutations, types, the build**

```bash
cd WT && for f in src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx src/components/insight-surface/InsightClientPreview.test.tsx src/services/insightSurface.test.ts; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
cd WT && node ./node_modules/next/dist/bin/next build 2>&1 | /usr/bin/grep -E "insights-tabs|Failed to compile|Module not found|Error:" | head -20
```

Expected:
- green, with the two button mutations failing their named tests (restore after each);
- tsc ≤ baseline;
- the build lists `/brands/[id]/settings/insights-tabs/preview/[[...tab]]`.

- [ ] **Step 7: Lint, format, commit**

```bash
cd WT && F=(src/services/insightSurface.ts src/components/insight-surface/InsightClientPreview.tsx src/components/insight-surface/InsightClientPreview.test.tsx "src/app/(dashboard)/brands/[id]/settings/insights-tabs/preview/layout.tsx" "src/app/(dashboard)/brands/[id]/settings/insights-tabs/preview/[[...tab]]/page.tsx" src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.tsx src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx src/components/brands/settings/sections/InsightsTabSettingsSection.tsx); H=("src/app/(dashboard)/brands/[id]/settings/insights-tabs/page.tsx"); ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" "${H[@]}" && /usr/bin/git add "${F[@]}" "${H[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): Insights Tabs — Preview as client

A read-only preview inside Brand Settings shows the portal's Insights as
a client would — only the tabs ticked under Clients, as saved — through
the agency's own session. Disabled while changes are unsaved.
Spec 2026-10-07 §4.3, §4.5.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 13: Theme / token pass for every surface the portal now renders

**Files:**
- Modify: `src/components/insight-surface/ShareInsightFrame.tsx`, `src/app/share/brand/[slug]/layout.tsx`, `src/components/insight-surface/pages/InsightSignalsPage.tsx`
- Modify: `src/lib/client-lane/tokenHygiene.test.ts` (the `FILES` list only)
- Modify: `src/lib/client-lane/tokenHygiene.publicPages.test.ts` (the `SURFACES` list only)
- Modify: `docs/tracks/client-portal.track.md`

**Interfaces:**
- Consumes: every file created or changed in Tasks 1–12.
- Produces:
  - the share dashboard's own grounds on `bg-app`;
  - banned-class scans over every new surface file;
  - a recorded three-theme pass.

The portal follows the viewer's appearance, and Daylight is the System default on a light device. The share dashboard drew its ground with `bg-[#111111]` and `bg-new-dark`. Daylight patches those (`theme-light.patches.css`), but Aurora does not (memory: dark hex is invisible to the Aurora sweep). `bg-app` is the shell token those literals stand in for (`globals.css`): identical in Midnight, right in Aurora and Daylight. The tab content components (charts, tables) are the app's own and already ship in all three themes, so they are checked, not rewritten.

- [ ] **Step 1: Extend the scans and prove they bite**

In `src/lib/client-lane/tokenHygiene.test.ts`, append to `FILES`:

```ts
  // Insights surfaces (spec 2026-10-07 §4) — agency + share, all themes.
  "src/components/insight-surface/InsightSurfaceLayout.tsx",
  "src/components/insight-surface/ShareInsightFrame.tsx",
  "src/components/insight-surface/SampleDataPill.tsx",
  "src/components/insight-surface/InsightTabRouter.tsx",
  "src/components/insight-surface/InsightSurfaceRoutePage.tsx",
  "src/components/insight-surface/InsightClientPreview.tsx",
  "src/components/insight-surface/pages/InsightSignalsPage.tsx",
  "src/components/brands/settings/insightsTabs/ClientVisibleCheckbox.tsx",
  "src/app/share/brand/[slug]/layout.tsx",
```

In `src/lib/client-lane/tokenHygiene.publicPages.test.ts`, append to `SURFACES`:

```ts
  // Portal Insights (spec 2026-10-07 §4.2) — follows the viewer's appearance.
  "src/components/client-lane/portal/PortalInsightsApp.tsx",
  "src/components/client-lane/portal/PortalInsightsRoute.tsx",
  "src/components/insight-surface/InsightSurfaceLayout.tsx",
  "src/components/insight-surface/SampleDataPill.tsx",
```

Run: `cd WT && bun test src/lib/client-lane/tokenHygiene.test.ts`
Expected: FAIL on exactly two entries, both `hex colour`:
- `ShareInsightFrame.tsx` (its two `bg-[#111111]`);
- `InsightSignalsPage.tsx` (the fallback's `text-[#b0b0b0]`).

The share `layout.tsx` passes, because `bg-new-dark` is not one of the banned patterns; Step 2 swaps it anyway. Any OTHER failing entry is a file this plan wrote: fix it with tokens. Then prove the public scan bites: add `text-white` to `SampleDataPill.tsx` temporarily, run `bun test src/lib/client-lane/tokenHygiene.publicPages.test.ts`, see it fail on that file, and remove the class.

- [ ] **Step 2: Fix the grounds**

- `ShareInsightFrame.tsx`: both `bg-[#111111]` → `bg-app`, on the `<main>` and on the scroll root.
- `src/app/share/brand/[slug]/layout.tsx`: the loader's `bg-new-dark` → `bg-app`.
- `InsightSignalsPage.tsx`: the Suspense fallback `<p className="text-sm font-geist text-[#b0b0b0]">` → `<p className="font-geist text-textSm text-text-inverse-subtle">`.

Run both scans again: green.

Then:

```bash
cd WT && bun run theme:patches:check
```

Expected: clean. If it reports the patches file stale (a hex class left use), run `bun run theme:patches` and add `src/app/theme-light.patches.css` to this task's commit.

- [ ] **Step 3: Three-theme pass (Daffa, or the executor with the browser pane)**

Theme switch: profile menu → Miscellaneous → Theme. For `/s`, a client with no preference gets System: flip the OS between light and dark.

Check, in Midnight, Aurora and Daylight:
1. **Portal Insights** (`/s/{ws}/{brand}/insights`):
   - the top bar and the nav ("Insights" selected);
   - the tab strip;
   - the title row with Filters and date range (Ads, Social Media, ATL);
   - the "Sample data" pill;
   - on every open tab: cards, charts, tables, empty states;
   - phone width 375px: no sideways page scroll, and the strip scrolls.
2. **Preview as client:** the banner, the strip, one tab.
3. **Insights Tabs settings:** the Clients ticks (checked, unchecked, disabled read-only) and the Preview button with its hint.
4. **Public share link `/share/brand/{slug}`:** unchanged in Midnight, and the ground follows Aurora.

Record ✓/✗ per item per theme in the track. A ✗ inside a tab's own content component (pre-existing dark literals in a chart or table) is NOT fixed here. List it in the track under "Follow-up: insight content dark literals" with file and line, and tell Daffa. A ✗ in any file this plan wrote is fixed now, with tokens.

- [ ] **Step 4: Commit**

```bash
cd WT && F=(src/components/insight-surface/ShareInsightFrame.tsx "src/app/share/brand/[slug]/layout.tsx" src/components/insight-surface/pages/InsightSignalsPage.tsx src/lib/client-lane/tokenHygiene.test.ts src/lib/client-lane/tokenHygiene.publicPages.test.ts docs/tracks/client-portal.track.md); ./node_modules/.bin/prettier --write src/components/insight-surface/ShareInsightFrame.tsx "src/app/share/brand/[slug]/layout.tsx" src/components/insight-surface/pages/InsightSignalsPage.tsx && /usr/bin/git add "${F[@]}" && /usr/bin/git add -u src/app/theme-light.patches.css && /usr/bin/git commit -F - <<'EOF'
fix(web): Insights grounds follow the appearance (bg-app), scans cover them

The share dashboard's frame and loader painted fixed #111111 / new-dark,
which Aurora never re-skins; the portal now renders it for clients on
System. Token scans cover every Insights surface this work added.
Spec 2026-10-07 §4.2.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 14: Gates, manual pass, Lark rows, contract reconciliation, track

**Files:**
- Modify: `docs/tracks/client-portal.track.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a branch ready for review (not pushed, no PR).

- [ ] **Step 1: Analytics completeness (memory: PostHog events are part of the feature)**

Load `frndos-analytics-events` and walk every interaction this plan adds:
- open Insights (portal nav);
- switch tab;
- tick or untick Clients and save;
- open the preview.

Then:

```bash
cd WT && /usr/bin/grep -rn "posthog.capture" src/components/insight-surface src/components/client-lane/portal/PortalInsights*.tsx src/components/brands/settings/insightsTabs || echo "no inline captures"
cd WT && /usr/bin/grep -rn "X-Share-Token\|session_token\|frnd_client" src/components/insight-surface src/components/client-lane/portal/PortalInsights*.tsx || echo "no token in the Insights client code"
```

Expected: `no inline captures` and `no token in the Insights client code`.

- [ ] **Step 2: Types, lint, banned classes, tests, build**

```bash
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
cd WT && BASE_SHA=$(/usr/bin/grep -oE "insights-base: [0-9a-f]{7,}" docs/tracks/client-portal.track.md | head -1 | cut -d' ' -f2); echo "$BASE_SHA"; /usr/bin/git diff --name-only "$BASE_SHA" -- src | /usr/bin/grep -E "\.(ts|tsx)$" > /tmp/portal-insights-touched.txt; ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -F -f /tmp/portal-insights-touched.txt
cd WT && tr '\n' '\0' < /tmp/portal-insights-touched.txt | xargs -0 ./node_modules/.bin/eslint
cd WT && /usr/bin/git diff -w "$BASE_SHA" -U0 -- src | /usr/bin/grep -E "^\+" | /usr/bin/grep -nE "\btext-white\b|white/\[0?\.[0-9]+\]|text-\[[0-9]+px\]|#[0-9a-fA-F]{6}\b" || echo "no banned classes on added lines"
```

`BASE_SHA` is the `insights-base:` sha that Task 0 recorded in the track; check that `echo` prints it. The file list goes through `xargs -0` because zsh would glob the `[slug]` / `[id]` / `(dashboard)` paths of an unquoted `$(cat …)`.

Expected:
- the count is ≤ the Task 0 baseline;
- the touched-file grep prints only lines listed as baseline;
- eslint shows 0 errors;
- `no banned classes on added lines`. The share frame's dark literals were fixed in Task 13, so they are not in the final diff, and `-w` hides the `ReportView.tsx` re-indent. If git reports a moved page body as a whole new file instead of a rename, its legacy classes show here: compare each hit with `git show "$BASE_SHA":<old path>` and keep only real additions as findings.

Every suite, one per invocation (the Task 0 list plus every new test):

```bash
cd WT && F=(src/components/brands/insight/DailySummaryOverview.test.tsx src/services/insightSurface.test.ts src/context/PublicShareContext.test.tsx src/services/insightReaders.test.ts src/lib/insight-surface/routes.test.ts src/lib/insight-surface/tabs.test.ts src/components/insight-surface/InsightSurfaceLayout.test.tsx src/lib/client-lane/portal/proxy.insights.test.ts src/lib/analytics/insights-client.events.test.ts src/lib/client-lane/portal/insightInfo.test.ts src/lib/client-lane/portal/insightInfoServer.test.ts src/services/client-portal.insights.test.ts src/components/client-lane/portal/PortalInsightsApp.test.tsx src/lib/insight-surface/sampleData.test.ts src/lib/insight-surface/clientVisibility.test.ts src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx src/components/insight-surface/InsightClientPreview.test.tsx "src/app/share/dashboard/[slug]/page.test.tsx" src/components/brands/reports/ReportsContent.test.tsx src/services/creative-analysis/hooks.test.ts src/hooks/useSocialListening.test.ts src/hooks/useBrandReports.test.ts src/constants/insightsTabs.test.ts src/components/frndos/DashboardFloatingChrome.test.tsx src/components/brands/insight/OwnedMediaFunnelSection.test.tsx src/lib/client-lane/portal/proxy.test.ts src/lib/client-lane/portal/me.test.ts src/lib/client-lane/portal/shell.test.ts src/services/client-portal.test.ts src/middleware.portal.test.ts src/middleware.mobile.test.ts src/middleware.kvShare.test.ts src/components/client-lane/portal/PortalApp.test.tsx src/components/client-lane/portal/PortalHeader.test.tsx src/components/client-lane/portal/PortalSignIn.test.tsx src/components/client-lane/portal/LaneExchange.test.tsx src/lib/client-lane/tokenHygiene.test.ts src/lib/client-lane/tokenHygiene.publicPages.test.ts src/lib/analytics/client-lane-events.portal.test.ts src/lib/theme.test.ts src/components/frndos/v2/Checkbox.test.tsx src/components/frndos/v2/ItemRow.test.tsx); for f in "${F[@]}"; do echo "== $f"; [ -f "$f" ] || { echo MISSING; continue; }; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
cd WT && /usr/bin/git diff --name-only "$BASE_SHA" -- 'src/**/*.test.ts' 'src/**/*.test.tsx' | while IFS= read -r f; do printf "%s " "$f"; wc -c < "$f"; done
```

Expected:
- every new file: `0 fail`, no `error` line;
- every old file: exactly its Task 0 failure list;
- every changed test file < 45 000 bytes.

Run the new component suites together once, to catch bun's process-global collisions (memory):

```bash
cd WT && bun test src/components/insight-surface/InsightSurfaceLayout.test.tsx src/components/client-lane/portal/PortalInsightsApp.test.tsx src/components/insight-surface/InsightClientPreview.test.tsx src/components/brands/settings/insightsTabs/InsightsTabSettingsForm.clients.test.tsx src/components/brands/insight/DailySummaryOverview.test.tsx 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"
```

Expected: the same pass count as the five separate runs. No new suite registers a module mock, so a difference means a shared spy was not restored.

Build:

```bash
cd WT && node ./node_modules/next/dist/bin/next build 2>&1 | tail -60
```

Expected:
- no `Failed to compile` or module-not-found;
- the route table lists `/share/brand/[slug]` and its eleven sub-routes;
- it also lists `/s/[token]/[brand]/insights/[[...tab]]` and `/brands/[id]/settings/insights-tabs/preview/[[...tab]]`.

- [ ] **Step 3: Security review**

Run the `security-review` skill on `git diff "$BASE_SHA"`. Hand it this threat list:
- **The BFF allowlist widening:** GET only, except `reports/query`; the 27 shapes; `safeSegments`; CSRF on the POST.
- **No client session token and no share token** in the portal's JS: the `X-Share-Token` header is only on the share surface.
- **The tab filter:** client-visible tabs only; a missing map opens nothing. The server enforcement is the api's 404; the web is UX only.
- **The preview endpoint's permission:** the api's job; the web sends the agency session.
- **Redirect targets** are built from server slugs and tab keys, never from query input.
- **The `insight-info` server fetch:** `no-store`, and null on 401/403/404.

Record the summary in the track. A high or critical finding blocks handover.

- [ ] **Step 4: Manual pass (Daffa — spec §4.6; laptop + phone)**

Setup:
- The api branch `feature/daffa/vc-client-portal` runs on :9191 with the `client_visible` migration applied, and deploys first.
- `cd WT && bun dev` on :3000, after stopping `web/`'s own server.
- The phone opens links via the laptop's LAN IP or a tunnel.

Record each line ✓/✗ in the track.

1. **Public share link unchanged.**
   - `/share/brand/{slug}`: every tab loads.
   - A protected link shows its wall, then its labels.
   - The Overview shows NO Review Signal, Ask a follow-up or refresh.
   - Trends → a signal opens its detail; Campaigns → a report opens.
   - On a demo brand, Listening → a topic opens.
   - Network: every call is `v1/share/brand/{slug}/insight/…` with `X-Share-Token` when protected.
2. **Settings.**
   - Brand Settings → Insights Tabs shows the Clients ticks (flag on), all off; no tick on Dashboard.
   - Tick Ads and Business, then Save: a toast, and the ticks survive a reload.
   - Workspace Insights Tabs has no Clients column.
   - PostHog Live Events: two `insights_tab_client_visibility_changed`, one per tab, after the save, not on the tick.
3. **Preview as client.**
   - The button is disabled with unsaved changes, and enabled after saving.
   - It opens the preview: banner, Ads and Business only, "Sample data" on Business.
   - A report opens inside the preview. Back to settings works.
   - `insights_preview_as_client_opened` fires once.
4. **Portal with tabs open.**
   - As a client (session), `/s/{ws}/{brand}` shows "Insights" in the nav.
   - It opens Ads and Business only. A deep link `…/insights/atl` lands on the first open tab.
   - Network: every call is `/s/api/portal/{ws}/{brand}/insight/…` with no `X-Share-Token`, and no response body carries a token.
   - Payloads: signals carry no `ideations`, and a report shows no creator row.
   - `client_lane.portal_insights_viewed` fires once per tab change.
5. **Portal with no tab open.** Untick everything: the nav has no Insights, and `/s/{ws}/{brand}/insights` goes straight to Approvals with no flash of a tab.
6. **Revocation while open.**
   - Untick the open tab in Settings, then switch tabs in the portal: the next call 404s, and the page moves to an open tab (or to Approvals if none is left).
   - Remove the client in the Clients tab: the next Insights action lands on the sign-in screen with no hint.
   - A report id that does not exist shows the report's own empty state, with no reload loop.
7. **`?k=` on an Insights URL.** A personal link with `/insights/paid-media?k=…` on a fresh device ends signed in on Ads.
8. **Phone (375px).**
   - The header compacts and the tab strip scrolls sideways; there is no page-level sideways scroll.
   - Charts are readable, and Filters and date range open.
   - `/share/brand` stays phone-blocked as before (middleware); only `/s` is opened.
9. **Themes:** Task 13 Step 3, repeated if Task 13 recorded "PENDING".

- [ ] **Step 5: Lark taxonomy rows (Daffa — signed-in session)**

List these in the track under "PENDING (human)", all new:

| Event | Props | Audience |
|---|---|---|
| `client_lane.portal_insights_viewed` | `tab` | public (anonymous, PII-free) |
| `insights_tab_client_visibility_changed` | `tab`, `visible` | agency |
| `insights_preview_as_client_opened` | — | agency |

- [ ] **Step 6: Reconcile the assumed contract**

Open `docs/superpowers/plans/2026-10-07-client-portal-insights-api.md` (workspace root), and, if it has landed, the api branch's routes and controllers. For each **(assumed)** item in this plan's "API contract assumed", record in the track: confirmed, or a mismatch plus its fix task. The items:
1. the `insight-info` keys (`brand_name` / `name`, `insights_tab_settings.resolved` / `tabs`);
2. hidden tabs: omitted, or `is_visible: false`;
3. `client_visible` per settings row; absent = false;
4. a null-label/visibility row with `client_visible: true` is kept;
5. a PUT row without `client_visible` leaves it untouched;
6. the preview route group and its paths;
7. the 27 mirrored paths, the same list as `INSIGHT_GET_PATHS` + ids + `reports/query`.

A mismatch in 1–2 changes `normaliseInsightInfo`; in 6, `previewInsightSurface` + `fetchClientPreviewInfo`; in 7, `insightRouteAllowed`. Each comes with its test. Do not hand-edit around a mismatch without a test.

- [ ] **Step 7: Track file and commit**

Update `docs/tracks/client-portal.track.md`:
- tick I1–I14 in "Insights checklist";
- append a session-log entry with:
  - the commits since the Insights base (`git log --oneline "$BASE_SHA"..HEAD | wc -l`);
  - the gate results (tsc vs baseline, eslint, every suite, the build);
  - the security-review summary;
  - the manual-pass results, or "PENDING (Daffa)";
  - the Lark rows;
  - the contract reconciliation;
  - the Listening sample-data decision (Task 10 Step 1);
  - every expectation fixed during a mutation check;
  - every test-tooling fallback used (`aria-pressed` vs `data-pressed`; StrictMode double effects);
  - the "Follow-up: insight content dark literals" list from Task 13.

Keep `status: in_progress` in the frontmatter until the PR merges (CLAUDE.md track rules).

```bash
cd WT && /usr/bin/git add docs/tracks/client-portal.track.md && /usr/bin/git commit -F - <<'EOF'
docs(web): record gates, manual pass and contract notes for portal Insights

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

Do NOT push and do NOT open a PR. The api deploys first, and Daffa opens both PRs.

---

## Self-review (run against the spec, 2026-10-07)

**1. Spec coverage (web parts)**

| Spec | Where |
|---|---|
| I-1 / §4.1: an `InsightSurface` context carrying transport, `basePath` and read-only; `PublicShareContext` keeps working | Task 2 (model + context), Task 3 (readers), Task 4 (bodies + hrefs) |
| §4.1 "~31 share readers take the surface" | Task 3. The code has 27 insight readers: 23 in `query.ts`, 1 in labelling, 3 in creative-analysis. `getBrandShareInfo` stays slug-based because it IS the share link's access step. |
| §4.1 "~8 hardcoded /share/brand/ hrefs use basePath" | Task 4 (campaigns, signal list, Overview's trends, two listening pages) and Task 5 (the layout's tabs and redirect). The rest are comments, the share-info call and `mutateBrandSharePassword`, which belong to the link itself. |
| §4.1 "the share layout's tab and header logic is extracted into one shared InsightSurfaceLayout, used by both routes" | Task 5 (share), Task 9 (portal), Task 12 (preview) |
| §4.2 the route `src/app/s/[token]/[brand]/insights/[[...tab]]/page.tsx`, BFF transport | Task 9 (route, layout, shell), Task 2 (portal surface) |
| §4.2 the proxy allowlist widens to the insight GETs + the reports query POST | Task 6 |
| §4.2 the middleware's portal regex includes the insights subpaths | Task 6 |
| §4.2 `PortalNav` enables Insights only with ≥1 client-visible tab | Task 8 (nav + approvals page), Task 9 (the Insights page's own nav) |
| §4.2 renders inside the portal shell, follows the viewer's theme, works on phones | Task 9 (`PortalFrame wide`, header, inline strip with `scrollOnMobile`), Task 13 (grounds + scans + three themes), Task 14 Step 4 item 8 |
| §4.2 / I-4 the "Sample data" pill | Task 10. The Listening rule goes to Daffa; see the contradictions below. |
| §4.3 the "Clients" column (v2 Checkbox), default off | Task 11 |
| §4.3 Preview as client, via the agency session, read-only, no lane | Task 12 (blocking api assumption stated) |
| §4.4 / I-6 DailySummaryOverview hides Review Signal, Ask a follow-up and refresh | Task 1 |
| §4.5 analytics | Task 7 (helpers); Tasks 9, 11 and 12 (wiring); Task 14 (Lark rows) |
| §4.6 pure rules: tab mapping and client filtering, the Sample-data rule, the proxy allowlist | Tasks 4–5 (`routes`, `tabs`), Task 10 (`sampleData`), Task 6 (`proxy.insights`); also surface URL building (Task 2) and the reader wire table (Task 3) |
| §4.6 existing share tests stay green | Task 0 baseline list, re-run in Tasks 2–5 and 14 |
| §4.6 manual: share unchanged, portal with and without tabs, revoked client, phone, three themes | Task 14 Step 4 (items 1, 4–6, 8, 9), Task 13 Step 3 |
| I-3: every access level sees the Insights tabs | No web branching on `access_level` anywhere in Tasks 8–9. The nav reads only `insight-info`. |
| I-5: client payload trims | api-side. The web tolerates them: the signal detail already hides `ideations` when `isPublicView`, and Task 9 Step 7 hides the creator row when `createdBy` is absent. |

**2. Placeholder scan:**
- There is no "TBD", "TODO", "similar to Task N" or "add error handling".
- Every code step shows its code. Edits to existing files quote the exact text they replace, or name the exact identifier.
- The two bulk edits are each exhaustive by file and call: Task 3 Step 5 lists every caller and reader call, and Task 4 Step 6 lists every function rename.

**3. Type consistency:**
- `InsightApi` / `InsightSurface` / `insightHref` / `insightRequest` (Task 2) are used unchanged by Tasks 3–5, 9 and 12.
- `SurfaceTabKey` (Task 4) is used by Tasks 5, 7, 9, 10 and 11.
- `ResolvedTabMap` / `surfaceTabs(resolved, audience)` (Task 5) are used by Tasks 8–10 and 12.
- `PortalInsightInfo` (Task 8) has the fields `brandId`, `brandName`, `brandLogo`, `ownedMediaTableView`, `resolved` in Tasks 9 and 12.
- `insightErrorAction` (Task 8) is used in Task 9.
- `portalInsightInfoKey` / `isPortalInsightInfoKey` (Task 9) share one key shape.
- `PortalNav` props (Task 8) are the same in Task 9.
- `InsightSurfaceLayout` props (Task 5) are used by Tasks 9, 10 and 12, and `onActiveTabChange` by Task 9.
- `clientsColumn` / `onPreviewAsClient` run through page → section → form (Tasks 11–12).

**4. Review Focus:** each of the five lines has its named test:
1. Task 5 (`tabs.test.ts`, `InsightSurfaceLayout.test.tsx`);
2. Task 9 (`PortalInsightsApp.test.tsx`, three tests);
3. Task 6 (`proxy.insights.test.ts`);
4. Task 3 (`insightReaders.test.ts`) and Task 1;
5. Task 8 (the PortalApp tests) and Task 9 ("goes back to Approvals…"), plus the server redirect.

**Spec ambiguities resolved here** (each is also noted where it applies):
1. **"Sample data" shows only to clients and in the preview, never on /share:** §4.2 places it under the portal, and /share stays unchanged.
2. **The Clients tick is independent of "Visible"** (I-2 "independent"). It exists on the nine surface tabs only; `dashboard` has no read-only page.
3. **The Clients column and the Preview are brand scope only, behind `show-client-lane`,** gated in the route files like the Members page's Clients tab.
4. **`insights_tab_client_visibility_changed` fires after a successful save,** once per tab whose saved tick changed, not per click. `portal_insights_viewed` fires once per active-tab change, deduped against StrictMode remounts.
5. **The preview lives at `/brands/{id}/settings/insights-tabs/preview/[[...tab]]` inside the settings shell** ("a read-only preview mode on the settings page"). It shows what is saved, so it is disabled with unsaved changes.
6. **The portal Insights shell lives in a server `layout.tsx`, with a client seam** (`PortalInsightsRoute`), so the header and strip survive tab switches. The `[[...tab]]` page renders only the body, and the same body serves the preview.
7. **Zero client-visible tabs:** no nav item; the URL redirects to Approvals on the server; an in-session drop to zero replaces to Approvals.
8. **In Insights, a 401 sends the client to sign-in; a 404 re-reads `insight-info`,** because a 404 there may only mean one tab was closed. The re-read decides between sign-in, Approvals, another tab, or nothing (a missing report).
9. **An `insight-info` outage hides the Insights nav item** instead of taking the Approvals page down.
10. **For a client, a missing tab map opens nothing.** The public link keeps its old "missing = visible" rule.
11. **The copy this plan had to choose** is listed under Global Constraints → Copy.

**Code ↔ spec contradictions found (for Daffa):**
1. **Listening "Sample data for non-demo brands" (I-4).** Non-demo brands render the connect-a-tool empty state, not fixtures; fixtures render only for the five demo brands. The literal rule labels an empty state. Task 10 Step 1 asks Daffa, and recommends labelling wherever fixtures render.
2. **Preview "through the agency's own session" (§4.3) has no endpoint in spec §3.** The portal endpoints need a client session, and the share endpoints need the public link on plus its token. This plan assumes an agency-authenticated `client-preview` group, and Task 12 is blocked until the api plan confirms it.
3. **§3.3 lists `{brand_id, name, logo, tabs, …}` but says the shape "matches getBrandResponse"** (`brand_name`, `brand_logo`, `insights_tab_settings.resolved`). The web reads both until reconciled (Task 14 Step 6).
4. **`resolvedMapToTabs` treats a missing tab as visible.** Reused for clients, a missing or partial map would open every tab. Task 5 adds the strict client rule; the server's 404 remains the real gate.
5. **Today's PortalNav shows Insights disabled with "Soon",** and `PortalApp.test.tsx` asserts that. The spec says it shows only with ≥1 client-visible tab, so the test changes (Task 8).
6. **The share dashboard's grounds are fixed dark literals** (`bg-[#111111]`, `bg-new-dark`): Daylight-patched, but invisible to Aurora. Rendering them in the theme-following portal needs the Task 13 swap to `bg-app`, which also changes /share in Aurora (Midnight is identical).
7. **The Insights Tabs form is frndOS v1, while the spec asks for a v2 Checkbox.** A wrapper file keeps v1 and v2 out of one file (Task 11).
8. **Settings PUT semantics:** today a row with `label: null, is_visible: null` is deleted server-side. A row that only carries `client_visible: true` must survive, which is an api change (assumed item 4).
9. **"~31 readers / ~8 hrefs" (§4.1):** the code has 27 insight readers and 6 real hrefs. The difference is the share link's own access calls and comments.
10. **`/share/brand/**` is phone-blocked by `middleware.ts`** (only `/share/dashboard` is admitted), so the share dashboard was never tuned for phones. `/s/**` is admitted, so the portal is where phone layout of the insight tabs is first exercised (Task 14 Step 4 item 8).
