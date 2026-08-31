---
title: Content Click Detail — carousel cards open the post/ad detail
slug: content-click-detail
author: fahmi
created: 2026-08-20
status: draft
services: [web, api, data-service]
---

# Content Click Detail — carousel cards open the post/ad detail

## Overview

Clicking a content thumbnail in the Paid Media and Owned Media insight carousels currently does
nothing. This feature makes those cards open the **existing** `BenchmarkRowDetailModal` — the same
detail surface the two benchmark tables already open — so "click content to see its detail" is true
on the carousels too.

Source: Lark [`recvsDcOxX4uxO`](https://fcn.sg.larksuite.com/record/O6dVr82aHeF36jcyU1nlaRTfgOd)
("Paid & owned media: Click content to show detail post or ads", Sprint 9, created by Darnilia
2026-08-18, assigned Fahmi, 1 point, Effort "Easy", Status "Ready for Dev"). **The ticket's
description and Definition of Done are both empty** — every requirement below is derived from the
code and from live mart data, not from the ticket.

Audience: brand and agency users on the Paid Media and Owned Media insight dashboards.

### Why this is not 1 point

The ticket's literal ask already ships on two surfaces. The unmet reading — the carousels — needs a
backend change on the paid side, because the paid creative-asset payload emits neither a caption nor
a post URL today. Scope is three services.

## Brainstorming Outcome

_Pulled verbatim from `features[content-click-detail].brainstorming.summary`._

The ticket's literal ask already ships on two surfaces (OwnedContentBenchmarkTable.tsx:379,
AdPerformanceExplorer.tsx:2146); the unmet reading is the content-thumbnail carousels, where
ContentCarouselItem.tsx:42 and ContentCarouselItemOwnedMedia.tsx:32 are inert divs whose only click
is the AskFRND select-toggle. Direction: both carousels open the existing BenchmarkRowDetailModal
with per-surface configs, and the shared modal is NOT edited — it already degrades safely without a
benchmark (:300, :169, :456, :425-430), verified in code. Two of the plan's premises were corrected
by drilling. First, owned link-to-post is NOT a real deferral: social_content_performance carries
media_permalink in its PRIMARY KEY (006_create_social_content_performance.sql:43,74) at 100%
population locally, the api DTO already declares mediaPermalink, and contentListFull already sets it
(OwnedMediaMapperService.php:1505) — only content_list.py's SELECT and one constructor arg at :1557
are missing, so §Deferred 1 rests on a false premise. Second, paid caption and post_url populate on
the same ~21-27% of mart rows (meta 127/478, google 95/448, tiktok 78/287, programmatic 0/119), so
the empty state is the common case and must be designed for, not treated as an edge. Paid still
needs real backend work: creative_assets.py:105-115 omits body / media_permalink / image_url, and
the correct post_url chain already exists in campaign_performance_detail.py:116-152 with both traps
documented — but note that file's `media_permalink` output alias actually carries the THUMBNAIL url
(:136) while the real link is `post_url`, so copying the alias would silently ship thumbnails as
links. Finally, the local ClickHouse predates orchestration d0f2bd8/f63d763, so local TikTok rows
still return ads.google.com landing URLs and cannot verify post-fix link correctness — that
assertion belongs on staging.

### Decisions

- **Owned link-to-post: PLAN §Deferred 1 was premised on `mediaPermalink` being absent. It is
  present and 100% populated.** → `include_owned_permalink`. In scope: one SELECT column in
  `content_list.py`, one constructor argument in `OwnedMediaMapperService.php`. The deferral is
  retired on evidence and needs a ledger row.
- **Paid caption/postUrl are empty on ~73% of mart rows even after the backend change.** →
  `hide_empty`. Empty fields render as absent — no caption block, no "Link to post" button, no
  placeholder copy. Mirrors the modal's existing per-tile benchmark degradation.
- **Local ClickHouse predates orchestration `d0f2bd8`, so a local TikTok post-link check proves
  nothing.** → `local_shape_staging_truth`. Locally assert query shape only; the "is this a real
  post link" assertion runs on staging.
- **Ticket reinterpretation (carousels, not the already-shipped tables).** →
  `proceed_with_ledger`. Proceed without waiting on Darnilia; record the reinterpretation and the
  scope bound in `docs/DECISIONS-LEDGER.md`.

### Existing System Reconciliation

What already exists that this PRD must not duplicate or break:

- **The behavior already ships on two surfaces.** `OwnedContentBenchmarkTable.tsx:379`
  (`onRowClick` → modal at `:439`) and `AdPerformanceExplorer.tsx:2146` (→ modal at `:2169`). This
  feature adds surfaces; it does not replace them.
- **`BenchmarkRowDetailModal` is shared by three consumers and must not be edited.** Its props are
  fully accessor-driven (`BenchmarkRowDetailModalProps` at `:92-133`), including the optional
  `getPostUrl` at `:131`. The "hide when empty" behavior of decision 2 is **already native**: the
  link block is gated `{postUrl && (...)}` at `:264`, and metric tiles render "No benchmark data"
  per tile at `:425-430` when `medians[col.id] ?? 0` is not > 0. Score hero is gated on
  `benchmark && quartileMeta` at `:300`, `quartileMeta` is null without a benchmark at `:169`, and
  the improvement CTA is gated at `:456`.
- **`AdRow.postUrl` already exists on the web side** (`AdPerformanceExplorer.tsx:234`, populated
  from `r.post_url` at `:1342`). The paid API just never emits it on the *creative-assets* payload.
- **The correct paid `post_url` SQL already exists** at
  `data-service/app/api/repositories/paid/campaign_performance_detail.py:116-152`, with the Google
  `final_urls` unwrap and the `video_url` exclusion both documented in comments.
- **`ContentPreviewDialog.tsx` is KOL-only** (sole consumer `KOLDetailsDialog.tsx:435`) and
  **`AdPreviewDialog.tsx` is dead code** — its consumer chain terminates in three files named
  `page_old_jeff.tsx`, which are not Next.js routes. Neither is a reuse candidate.
- **`web/docs/prd/paid-media-reskin.md` is stale** (created 2026-05-12, `status: draft`, track
  0/9 tasks) but covers a *different* concern — making `PaidMediaInsightsV2` the default layout.
  No overlap with this feature. It still needs a supersede banner, tracked separately.

### Assumptions and Clarifications

- **The carousel has no cohort, so it has no medians.** `medians={{}}` and `allRows={[]}` are
  passed deliberately; every metric tile will read "No benchmark data". This is the modal's
  designed degradation, not a defect.
- **Caption has no dedicated block in the modal.** It surfaces through `getTitle` — the owned table
  already does exactly this (`getTitle={(r) => r.caption?.trim() || r.username || "Post"}`). Paid
  keeps the ad name as the title and does **not** get a caption block, because adding one would
  edit the shared modal. `caption` is therefore fetched for paid to drive the title fallback and
  future use, not to render a new region.
- **`landing_page_url` is a dead fallback arm.** `api/app/api/v1/reports.py:755` states it is
  "empty for every row". It stays in the chain for the day it is repopulated.
- **The paid carousel exposes 4 metrics** (conversion, impressions, clicks, reach) versus the 25+
  in `paidBenchmarkColumns.tsx`. `visibleCols` is passed a 4-column subset, not `METRIC_COLUMNS`.

## User Stories

- As a **brand user on Paid Media**, I want to click a creative-asset card, so that I can see that
  ad's metrics and jump to the live ad without hunting for it in the Ad Performance Explorer.
- As a **brand user on Owned Media**, I want to click a content card, so that I can read the full
  caption and open the real post.
- As a **keyboard user**, I want to reach a card with Tab and open it with Enter or Space, so that
  the new interaction is not mouse-only.
- As an **AskFRND user**, I want clicking a card in select mode to keep selecting it for comparison,
  so that the new detail click does not break the existing point-and-ask flow.

## Requirements

### Functional Requirements

- **FR-1:** Clicking a paid creative-asset card in `CreativeAssets.tsx` opens
  `BenchmarkRowDetailModal` with `surface="insights_paid"` and `entityType="ad"`.
- **FR-2:** Clicking an owned content card in `insight/ContentPerformance.tsx` opens
  `BenchmarkRowDetailModal` with `surface="insights_owned"` and `entityType="post"`.
- **FR-3:** When `isAskFRND` is true, a card click **selects** the widget and does **not** open the
  modal. The card's own handler must no-op in that mode, and must not swallow the parent's
  `[data-action-btn]` guard (`CreativeAssets.tsx:163`).
- **FR-4:** A clickable card exposes `role="button"`, `tabIndex={0}`, `cursor-pointer`, a hover
  treatment, and an `onKeyDown` handler for Enter and Space. `Esc` closes the modal (already handled
  by the modal).
- **FR-5:** Both carousels show a discoverability hint near the header, wording
  `Click a card for details`, matching the existing pattern at `AdPerformanceExplorer.tsx:2165`.
- **FR-6:** The paid creative-assets payload gains `caption`, `postUrl` and `mediaSrc` as
  **additive optional** fields. No existing field is renamed, removed, or reshaped.
- **FR-7:** `data-service` selects `body`, the `post_url` fallback chain, and `image_url` on the
  creative-assets query, using `argMax` keyed on `(candidate != '', impressions)`.
- **FR-8:** The owned `contentList` payload gains `mediaPermalink`, sourced from
  `social_content_performance.media_permalink`.
- **FR-9:** Empty `caption` / `postUrl` render as absent — no placeholder text, no disabled control.
- **FR-10:** Metric tiles in a carousel-opened modal read "No benchmark data"; the score hero and
  "vs typical" deltas are absent. No crash, no blank box.
- **FR-11:** `ContentCarousel`'s `CarouselItem` interface gains optional `caption?`, `postUrl?` and
  `benchmark?`. They must be optional so the KOL and report consumers of `ContentCarousel` are
  untouched.
- **FR-12:** Google's `media_permalink` arrives as a stringified `final_urls` array and is unwrapped
  exactly as `campaign_performance_detail.py:117-119` does.
- **FR-13:** `video_url` is never used as a post link, on any platform.

### Non-Functional Requirements

- **NFR-1:** `BenchmarkRowDetailModal` is not modified. Any change that appears to require editing
  it is out of scope and must be raised instead.
- **NFR-2:** No new API request. `creativeAssets` already ships on `/paid-media/detail`
  (`PaidMediaDetailResource.php:10`) and the paid page already calls it.
- **NFR-3:** The three new paid `SELECT` expressions add no new `GROUP BY` key — the group stays
  `1,2,3,4,5`, collapsed by `ad_name`.
- **NFR-4:** `web` `npx tsc --noEmit` error count must not increase over its known non-zero
  baseline (448 as of `home-morning-briefing`).
- **NFR-5:** Contract guard — this is a UI-driven task, so it may add API fields but may not rename
  an existing field, change a response shape, or alter a SQL grain or threshold.

## Service Breakdown

### API (`api/`)

- Add `caption`, `postUrl`, `mediaSrc` as nullable strings to
  `app/Data/BrandInsight/PaidMedia/CreativeAssetItemData.php:9-21`.
- Map the new data-service keys onto them in
  `app/Services/BrandInsight/PaidMediaMapperService.php:341-359`.
- Owned: pass `mediaPermalink: $item->permalink ?? null` in the `contentList` branch of
  `app/Services/BrandInsight/OwnedMediaMapperService.php:1557-1577`. **No DTO change** — the owned
  `ContentItemData` already declares `mediaPermalink`, and `contentListFull` already sets it at
  `:1505`.
- Add `permalink` to the data-service-facing owned DTO
  (`App\Data\DataService\OwnedMedia\ContentItemData`) so the value survives deserialization.

### Frontend (`web/`)

- `src/components/brands/ContentCarousel.tsx:15-32` — extend `CarouselItem` with optional
  `caption?`, `postUrl?`, `benchmark?`.
- `src/components/brands/ContentCarouselItem.tsx` (paid) and
  `src/components/brands/ContentCarouselItemOwnedMedia.tsx` (owned) — accept optional
  `onSelect?: () => void`; apply the FR-4 affordances only when it is present.
- `src/components/brands/CreativeAssets.tsx` — thread the new API fields through the `Asset`
  mapping (`:66-101`), add `useState<CarouselItem|null>`, wire the modal mirroring
  `AdPerformanceExplorer.tsx:2169-2194` (`getMetaLines` → Campaign / Adset / Platform · Stage),
  with `medians={{}}`, `allRows={[]}`, and a 4-column `visibleCols` subset.
- `src/components/brands/insight/ContentPerformance.tsx` — the `carouselItems` memo at `:48-64`
  currently drops `caption`; add it, plus `mediaPermalink` and `benchmark`. Wire the modal
  mirroring `OwnedContentBenchmarkTable.tsx:439-461` (`getTitle` = caption → username → "Post";
  `getMetaLines` → Account / Stage / Content Format).
- Omit `footerSlot` on both — `CreativeAnalysisPanel` is flag-gated and table-scoped.

### AI Service (`ai-service/`)

Not touched.

### Data Service (`data-service/`)

- `app/api/repositories/paid/creative_assets.py` — add to the `SELECT` at `:105-115`:
  `argMax(COALESCE(pap.body,''), pap.impressions) AS body`; the `post_url` candidate chain copied
  from `campaign_performance_detail.py:116-119` wrapped as
  `argMax(post_url_candidate, (post_url_candidate != '', pap.impressions))`; and
  `argMax(coalesce(pap.image_url,''), pap.impressions) AS image_url`. Sort key is `impressions`
  (this file's existing order), not `cost`. Pass the three keys through the result dict at
  `:161-177`.
- `app/api/repositories/owned/content_list.py` — add
  `coalesce(scp.media_permalink,'') as permalink` to the `SELECT` at `:259-273`. The column is in
  the table's PRIMARY KEY, so no index or grain change.

### Orchestration (`orchestration/`)

Not touched. Noted only because `d0f2bd8` and `f63d763` are what make paid post links real, and the
local mart predates both.

## UI/UX

Implementation strategy is **implementation_only** — no wireframe stage, because the detail surface
already exists and ships. This section is informational.

### Key Screens

- **Paid Media insight → Creative Assets carousel.** Cards gain a pointer cursor and hover
  treatment. Clicking opens the shared modal: thumbnail, ad name as title, meta lines
  Campaign / Adset / Platform · Stage, four metric tiles each reading "No benchmark data", and a
  "Link to post" affordance only on the ~27% of rows that have one.
- **Owned Media insight → Content Performance carousel.** Same interaction. Title is the caption
  (falling back to username, then "Post"), meta lines Account / Stage / Content Format, and
  "Link to post" on effectively every row.
- **AskFRND select mode, both carousels.** Unchanged: a card click adds/removes the widget from the
  chat context and the modal never opens.

## Data Model

### New Tables

None.

### Modified Tables

None. Every column read already exists:

| Column | Table | Evidence |
|---|---|---|
| `body` | `frnd_agg_marts.paid_ads_performance` | `001_create_paid_ads_performance.sql:60` |
| `media_permalink` | `frnd_agg_marts.paid_ads_performance` | `:64` |
| `image_url` | `frnd_agg_marts.paid_ads_performance` | `:62` |
| `media_permalink` | `frnd_agg_marts.social_content_performance` | `006_create_social_content_performance.sql:43`, in PRIMARY KEY at `:74` |

Measured population (local ClickHouse, 2026-08-20):

- Paid — `body` and `media_permalink` populate on the same rows: meta 127/478 (26.6%), google
  95/448 (21.2%), tiktok 78/287 (27.2%), programmatic 0/119 (0%).
- Owned — `media_permalink` at 100%: source 0 → 1220/1220, source 1 → 360/360, source 3 → 18/18.

## API Endpoints

No new or removed endpoints. Two existing responses gain optional fields.

| Method | Endpoint | Description | Service |
|--------|----------|-------------|---------|
| GET | `v1/brands/{id}/insight/paid-media/detail` | `creativeAssets.assets[]` gains optional `caption`, `postUrl`, `mediaSrc` | api |
| GET | `v1/brands/{id}/insight/owned-media` | `contentList[]` gains optional `mediaPermalink` | api |
| GET | *(internal)* `/paid/creative-assets` | result rows gain `body`, `post_url`, `image_url` | data-service |
| GET | *(internal)* `/owned/platform/content` | result rows gain `permalink` | data-service |

## Acceptance Criteria

- [ ] **AC-1:** Clicking a paid carousel card in normal mode opens the modal with the correct
      thumbnail and ad name.
- [ ] **AC-2:** Clicking an owned carousel card in normal mode opens the modal with the caption as
      title and the correct thumbnail.
- [ ] **AC-3:** In AskFRND mode, clicking a card on either carousel **selects** it and the modal
      does not open.
- [ ] **AC-4:** Tab reaches a card, Enter opens the modal, Space opens the modal, Esc closes it.
- [ ] **AC-5:** In a carousel-opened modal every metric tile reads "No benchmark data", and the
      score hero and "vs typical" deltas are absent — no blank box, no crash.
- [ ] **AC-6:** On a paid row with `media_permalink`, "Link to post" opens the real ad. On a paid
      row without one, the affordance is absent — not disabled, not a placeholder.
- [ ] **AC-7:** On an owned row, "Link to post" opens the real social post.
- [ ] **AC-8:** `GET .../paid-media/detail` returns `creativeAssets.assets[].caption` and
      `.postUrl`, and the 10 pre-existing asset fields are unchanged in name, order and type.
- [ ] **AC-9:** No paid row returns a `video_url`-shaped URL as `post_url`; a Google row's
      `post_url` is a bare URL, not a stringified array. **Asserted on staging** — local data
      predates orchestration `d0f2bd8` and cannot show post-fix shape.
- [ ] **AC-10:** Regression — opening a row in the Content Posts table and in the Ad Performance
      Explorer still renders the score hero and real medians. This is the shared-modal check.
- [ ] **AC-11:** `npx tsc --noEmit` in `web` does not increase the error count over its 448-error
      baseline.
- [ ] **AC-12:** `docs/DECISIONS-LEDGER.md` carries a row for the ticket reinterpretation and a row
      retiring the owned link-to-post deferral, both in the same commit as the change.

## Open Questions

- [ ] **Q-1:** `programmatic` has 0% `body`/`media_permalink` coverage (0/119 rows). Should
      programmatic cards still be clickable, given the modal will show only a thumbnail and four
      "No benchmark data" tiles? Current spec says yes, for click-affordance consistency (FR-1).
- [x] **Q-2 — ANSWERED 2026-08-28: folded in NOW, into this PR.** Fahmi, verbatim: "only add this
      on social media, but leave it be on the ads". Both owned `BaseTable`s
      (`insight/SocialMediaPerformance.tsx` "Performance by Platforms",
      `insight/ContentPerformance.tsx` "Metrics Summary") now open `BenchmarkRowDetailModal`;
      the four paid Performance Breakdown tables stay deferred. Shipped in web #478 as TASK-12 /
      TASK-13. **Cost, stated and accepted:** these rows are aggregates, not posts — no creative,
      no permalink, no cohort — so both modals render without the score hero, the "vs typical" chip
      and the "Link to post" affordance. Ledger row: `W9`.
- [ ] **Q-3:** `mediaSrc` (FR-6) is specified but has no consumer in this feature, since the modal
      renders `getThumbnail`. Ship it as forward-looking, or drop it until something reads it?

## Deferred — found while drilling, NOT in this feature

Carried from `PLAN-content-click-detail.md` §Deferred so they are not lost. Item 1 of that list is
**retired** — owned link-to-post is now in scope (FR-8). **Item 2 is also retired** as of
2026-08-28 — see the banner on it and Q-2.

1. **4 paid "Performance Breakdown" tables have zero click** — `PlatformPerformanceTable` plus
   Awareness / Consideration / Conversion. Hand-rolled `<table>`, no `onRowClick` support.
2. > ⛔ **SUPERSEDED** by Q-2 / `W9` (2026-08-28). Kept for history — do not build from this.
   >
   > **Owned "Performance by Platforms"** `SocialMediaPerformance.tsx:366` and **"Metrics Summary"**
   > `ContentPerformance.tsx:321` — both `BaseTable`, which supports `onRowClick` at `:396`. One
   > line each. See Q-2.
   >
   > Both are now IN SCOPE and implemented (web TASK-12 / TASK-13). The "one line each" estimate
   > was wrong: `onRowClick` is one line, but each surface also needs its own modal element, a
   > `MetricColumn[]` mirroring the table's formatters, an `isAskFRND` guard, a
   > `buildAskFrndSection`, and — for `SocialMediaPerformance` — a new `brandId` prop threaded
   > from `insight/OwnedMediaContent.tsx`.
3. **Share-context modal CTAs are silent no-ops.** `BenchmarkRowDetailModal.tsx:440,:454` render
   enabled buttons; `useAskFRNDContext()` falls back to `openChat: () => {}`
   (`AskFRNDContext.tsx:38`) because no provider wraps `src/app/share/brand/[slug]/layout.tsx`.
   Needs `isPublicView` gating — pattern exists at `SentimentDetailDialog.tsx:224`.
4. **Owned share + shared-workspace pages never pass `brandId`** —
   `share/brand/[slug]/owned-media/page.tsx:22`, `workspaces/…/owned-media/page.tsx:56`. Starves
   `useBrandLabelAttributes("")` / `useConnectedAccounts("")`, both `enabled: !!brandId`.
5. **`appliedFilters` dropped on 2 of 4 paid routes** — `insight/dashboard/paid-media/page.tsx`.
   The explorer shows an unfiltered row set there.
6. **Public-share explorer auth mismatch** — `lib/user-type.ts:89` regex misses `/share/brand/`, so
   `getExplorerPaidData` runs unauthenticated and silently falls back to adset rows with
   `thumbnail: ""`.
7. **`AdRow` declared twice** — `paidBenchmarkColumns.tsx:17` and `AdPerformanceExplorer.tsx:220`.
   Manual sync, drift risk.
8. **Owned table has no "Click row for details" hint or quartile legend** —
   `OwnedContentBenchmarkTable.tsx:306`. Same omission at `KOLPostsBenchmarkTable.tsx:443`.
9. **`DataTable` clickable rows get `cursor-pointer` but no hover background**
   (`DataTable.tsx:668`) versus `BaseTable.tsx:401`, which has both.
10. **Dead code to remove separately:** `ContentCarouselOwnedMedia.tsx` (180 lines, zero imports),
    `AdPreviewDialog` plus its three-deep `page_old_jeff.tsx` chain, `OwnedMediaFunnelSection`
    (commented out, `OwnedMediaContent.tsx:212`), `CampaignPerformanceTable` (1867 lines, commented
    out, `PaidMediaContent.tsx:1157`).
11. **`web/docs/prd/paid-media-reskin.md` + track are stale** — 0/9 tasks, last session 2026-05-12,
    references a moved path. Needs a supersede banner + ledger row, or a future session builds from
    a dead spec.
12. **The local ClickHouse mart predates orchestration `d0f2bd8` / `f63d763`.** Any local check of
    paid post-link correctness is structurally blind. Worth refreshing independently of this
    feature.
