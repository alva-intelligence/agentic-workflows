---
title: Insights — Missing Metrics on Paid Breakdown and Owned Post List
slug: insights-missing-metrics
author: fahmi
created: 2026-08-19
status: draft
services: [data-service, api, web]
---

## Overview

Two Lark Sprint-9 records ask for the same class of thing — metrics that exist in the
warehouse but never reach the dashboard:

| Record | Ask |
|---|---|
| `recvsD3k5rFXBp` — Paid media: performance breakdown | "Add any metric that has not available in frndOS on the performance breakdown table. E.g. 1. Leads 2. CPL" |
| `recvsD6Q6rLgMQ` — Owned media: Post list | "…E.g. 1. Avg. views 2. 3 secs views" |

Both close with **"Please do add any metric that is crucial but still missing in frndOS"** —
so the named metrics are examples, not the boundary.

They are combined into one feature because they share three services, one branch set, and —
more importantly — one root cause. Investigating "why is CPL missing" surfaced that the
metrics already on these surfaces are computed in a way that produces wrong numbers. Shipping
a correct CPL next to a CPM that is wrong by 65× would be worse than shipping neither.

**Audience:** brand marketers reading the Paid Media → Performance Breakdown funnel tables
and the Owned Media → Content Posts table.

### The shaping constraint: base metrics vs derived metrics

A derived metric cannot be averaged across a group. `avg(cpl)` over ad-day rows gives a
low-spend row the same weight as the campaign's biggest spender. The only correct form is
`sum(numerator) / sum(denominator)`, computed once, at the grain the response groups by.

This splits every metric into two tiers:

- **Tier A — base / additive.** Lives as a column in the mart. Safe to `sum()`.
  Cost, impressions, reach, clicks, link_clicks, leads, landing_page_view, video_views,
  thruplays, purchase_count, purchase, engagement.
- **Tier B — derived / ratio.** Computed **in data-service at query time** from summed
  Tier-A components. Never stored, never read back from a precomputed mart column, never
  `avg()`'d. CPL, CPM, CPC, CPP, CPV, CPLPV, CTR, ROAS, frequency, every rate.

**A DDL change is therefore needed only when a new Tier-A column is missing from the mart.**
Tier-B metrics never touch DDL — that is precisely what allows them to be re-aggregated at
any grain. This rule is expected to govern many more custom metrics later, so it is encoded
as a shared module rather than applied case by case.

### Measured evidence (live staging, read-only)

`avg()`-of-ratio is not hypothetical here. `performance_summary.py:83` is
`round(avg(pap.cpm),2)`. Measured against the correct ratio form:

| funnel · platform | shipped today | correct | error |
|---|---|---|---|
| Awareness · google | 6,850.00 | 26.91 | 255× |
| Awareness · meta | 2,989.12 | 98.20 | 30× |
| Consideration · tiktok | 8,012.91 | 125.56 | 64× |
| Conversion · meta | 14,002.75 | 187.32 | 75× |

The same trap was pre-loaded for CPL: the mart stores a precomputed `cost_per_leads`, and
`avg(cost_per_leads)` yields 29,241 where the truth is 33.02.

**Three separate instances of this pattern exist** — `performance_summary.py:83`,
`PaidMediaMapperService::aggregatePlatformData`, and `PaidMediaMapperService:607/769`. It
recurs because nothing currently forbids it.

### Prior art — this overlaps an existing open item

An earlier session the same day filed this bug family as **`OUT-019`** in
`data-service/docs/OUTSTANDING.md`, with its own staging measurements, plus two **open
conflicts** in `data-service/docs/DECISIONS-LEDGER.md`:

- **M1 — `cpv` denominator.** `sum(cost)/sum(video_views)` (`performance_summary.py:84`)
  vs `sum(cost)/sum(landing_page_view + video_views)`
  (`campaign/paid_performance.py:217`). Both are ratio-of-sums; they simply define "a view"
  differently.
- **M2 — owned ER denominator.** `engagement/impressions` vs `engagement/reach`.

That entry states: *"whoever fixes OUT-019 does not silently settle them by touching
whichever file they opened first. Decide, record the decision here, then fix."*

**This feature respects that.** It fixes `cpm` and `cpp`, which are unambiguous. It does
**not** touch `cpv` or the owned ER denominator. Its ledger rows are labelled **N1–N6** to
avoid colliding with the existing `M1`/`M2`, and they cross-reference `OUT-019` rather than
re-reporting it as new.

## User Stories

- As a **brand marketer**, I want Leads and CPL on the Paid Media performance breakdown, so
  that I can judge lead-generation efficiency per platform without exporting to a
  spreadsheet.
- As a **brand marketer**, I want video Views on the Owned Media post list, so that I can
  compare video reach against impressions per post.
- As a **brand marketer**, I want the cost metrics I already read (CPM, CPP) to be correct,
  so that decisions made from them are not off by one to two orders of magnitude.
- As a **performance analyst**, I want Frequency, Thruplays and Link Clicks on the funnel
  tables, so that I can diagnose creative fatigue and video-completion drop-off in the same
  view as spend.
- As a **data engineer**, I want the base-vs-derived rule encoded in one module, so that the
  next endpoint cannot reintroduce `avg(ratio)` by accident.

## Requirements

### Functional

- **FR-1** — `/api/v1/paid/performance` returns `cpl` on every `platform_performance` row,
  computed as `sum(cost) / NULLIF(sum(leads), 0)`.
- **FR-2** — the same endpoint returns `cpl` inside `summary_performance.consideration`,
  computed from the summed components, not by averaging the per-row values.
- **FR-3** — the same endpoint returns `frequency`, `thruplays`, `link_clicks` and
  `cost_per_thruplay` on every `platform_performance` row.
- **FR-4** — `cpm` on that endpoint changes from `avg(pap.cpm)` to
  `sum(cost) * 1000 / NULLIF(sum(impressions), 0)`.
- **FR-5** — `cpp` on that endpoint changes denominator from `sum(purchase)` (an IDR value)
  to `sum(purchase_count)` (an event count), closing `OUT-010` for this endpoint.
- **FR-6** — `/api/v1/owned/posts` returns `video_views` and `engagement` inside its nested
  `metrics` object.
- **FR-7** — the existing `views` field on `/owned/posts` keeps its current meaning
  (`= impressions`). It is **not** redefined or renamed.
- ~~**FR-8** — the mislabelled `/paid/detail` field `cost_per_unique_click` is renamed
  `cost_per_link_click` end to end.~~ ⛔ **CUT 2026-08-20 — built, then reverted in full.**
  The field keeps its name. Cut on blast-radius grounds: it is shipped API contract that
  `CampaignDetailData.php:46` deserializes by name via a promoted, defaultless Spatie Data
  property, reached by three api paths including **public share links** and the AskFRND
  vectoriser — and warm `brand-insight` cache entries would carry the old key, needing a
  deploy-time flush nothing had specified. The finding (the field divides by `link_clicks`
  while naming a metric that has never existed here) is preserved as **OUT-025**. The
  mean-of-ratios repair on the api side is **not** cut — it survives as api TASK-5, and is
  covered by FR-11.
- **FR-9** — `frnd_agg_marts.social_content_performance` gains a `duration_seconds`
  column, and the transformer projects it. Not surfaced on any endpoint by this feature.
- **FR-10** — the web funnel tables render the new paid metrics, and the owned benchmark
  table renders video Views.
- **FR-11** — every totals/aggregate row for a Tier-B metric, in SQL and in TypeScript,
  uses summed-numerator ÷ summed-denominator.
- **FR-12** *(added 2026-08-21 — supersedes the Instagram half of the watch-depth
  exclusion below)* — six Instagram per-post metrics travel from raw to the Content Posts
  table: `new_follows`, `reposts`, `avg_watch_time_ms`, `total_watch_time_ms`,
  `skip_rate_3s`, `retained_views_3s`. Four layers: `instagram_business.yaml` allow-list,
  `flows/instagram_business/transform_flow.py`, mart migration `v2/022`, then
  `/owned/posts` → api `ContentItemData` → `ownedBenchmarkColumns.tsx`.

  Three constraints are part of the requirement, not implementation detail:

  1. **All six are NULL-preserving end to end.** Instagram is the only platform whose
     transform emits them, so Facebook/TikTok/YouTube rows are null, and within Instagram
     the watch-time and skip columns are reels-only. Null means "not reported" and must
     never render or aggregate as 0 — the same rule `clicks` already follows.
  2. **`avg_watch_time_ms` is a per-viewer mean and may never be summed or averaged.**
     Every rollup is `sum(total_watch_time_ms) / sum(video_views)`; the totals row for
     `skip_rate_3s` is likewise recomputed as `100 × (1 − Σretained ÷ Σviews)`. This is
     FR-11's rule applied to owned.
  3. **`retained_views_3s` is an estimate and stays labelled as one.** It must not be
     merged into `video_views`, which is a *measured* ≥3s count on Facebook.

### Explicitly out of scope

- **`cpv` denominator** and **owned ER denominator** — blocked by ledger conflicts M1/M2.
- **A cross-platform "3 second views" metric** — see Data Model; it cannot be assembled
  from incomparable per-platform thresholds.
- ~~**Meta watch-depth columns** (15s, 60s, avg time watched, completion) — present in raw
  but not Fivetran allow-listed; four layers of change, separate ticket.~~
  ⛔ **SUPERSEDED 2026-08-21 by FR-12 (ledger `N8`) for the Instagram half only.** Kept for
  history — do not build from this line where Instagram is concerned. All four layers were
  built for Instagram at the owner's direction: Fivetran YAML, transformer, mart migration
  `v2/022`, and the serving stack. **The Facebook half of this exclusion still stands** —
  `lifetime_post_metrics_total`'s six watch-depth columns and
  `lifetime_reel_metrics_total`'s watch-time/follows columns remain out of the allow-list
  and out of scope.
- **`unique_clicks`** — structurally empty at source; never selected in the Fivetran report.
- **Dropping the mart's precomputed `cost_per_*` / `*_rate` columns** — Prefect writes them;
  removal is a separate coordinated change. They become deprecated-for-reads only.

## Non-Functional Requirements

- **Performance** — no new table scans. Every added metric is another aggregate over rows
  the query already reads. `paid_ads_performance` is read with `FINAL`, unchanged.
- **Tenancy** — all reads continue through `TenantClient`; RLS is untouched. No tenant
  `WHERE` clause is added.
- **Compatibility** — every new api DTO field is nullable-with-default so payloads from an
  older data-service still deserialize.
- **Safety** — the migration is metadata-only (`ADD COLUMN` on MergeTree). Per
  `data-service/AGENTS.md` §4 an agent must never execute DDL against Cloud: the SQL is
  prepared here and **run by a human**.
- **Correctness disclosure** — FR-4 and FR-5 change customer-visible numbers by 30–255×.
  Before/after tables must appear in the PR body and be raised with the requester.

## Service Breakdown

### data-service
- New `_metrics.py` module encoding the Tier-A / Tier-B rule.
- Rewrite the `/paid/performance` SELECT from that module (FR-1 … FR-5).
- Add `video_views` + `engagement` to `/owned/posts` (FR-6, FR-7).
- ~~`cost_per_link_click` rename (FR-8).~~ **CUT** — see FR-8.
- Migration `v2/021` for `duration_seconds` (FR-9).
- Ledger rows N1–N6.

### api
- Passthrough DTO fields for every new metric.
- Fix `aggregatePlatformData` mean-of-ratios (FR-11).
- Fix the `cost_per_unique_click` mean-of-ratios in three mapper functions (FR-11). The
  rename half is **cut**.
- Correct the swapped reach/impressions comments in `facebook_pages.yaml`.

### web
- New columns on the funnel tables and the owned benchmark table (FR-10).
- Sum-ratio totals rows (FR-11).
- Type updates and the `costPerLinkClicks` rename.

### frnd-orchestration (fourth repo, outside the frndOS harness)
- Guarded `duration_seconds` projection into `social_content_performance`.
- **Blocked twice over:** the repo currently holds 29 staged files of unrelated observatory
  work on `feat/observatory-m0`, and the projection cannot land until the `v2/021` ALTER has
  been applied by a human. The transformer names columns explicitly in its INSERT, so
  projecting a column that does not yet exist fails the load for every platform in that
  UNION.

## Data Model

**No DDL is required for any metric either Lark record names.** Verified against the live
staging cluster via `system.columns`, not against the migration files (which are known to
drift from Cloud).

| metric | mart column | exists live? |
|---|---|---|
| Leads | `paid_ads_performance.leads` | yes |
| CPL | *derived* `sum(cost)/sum(leads)` | n/a — Tier B |
| Frequency | *derived* `sum(impressions)/sum(reach)` | n/a — Tier B |
| Thruplays | `paid_ads_performance.thruplays` | yes |
| Link clicks | `paid_ads_performance.link_clicks` | yes |
| Views (owned) | `social_content_performance.video_views` | yes |
| Engagement (owned) | `social_content_performance.engagement` | yes |

Live coverage, rows with value > 0:

| platform | rows | leads | thruplays | frequency | link_clicks |
|---|---|---|---|---|---|
| tiktok | 444,975 | 124 | 63,786 | 72,551 | 63,515 |
| meta | 199,441 | 18,033 | 9,977 | 151,736 | 126,989 |
| google | 66,346 | **23,089** | 162 | 162 | 50,527 |

Google is the **largest** lead source, via `custom_report_lead`
(`all_conversions` where `conversion_action_category IN ('SUBMIT_LEAD_FORM','CONTACT')`).

| channel | rows | video_views > 0 | engagement > 0 |
|---|---|---|---|
| facebook | 4,409 | 1,766 | 4,379 |
| instagram | 2,749 | 2,744 | 2,701 |
| TikTok | 99 | 99 | 99 |
| YouTube | 104 | 61 | 104 |

### The one real DDL gap

Diffing every staging column against every mart column found exactly two the transformer
computes and the mart discards:

- **`duration_seconds`** — present in all four `*_content_performance` staging tables,
  absent from the mart. FB 1,768 of 4,409 rows populated. **In scope** (FR-9). It is the
  denominator for completion rate, average watch percentage and hook rate; none of those are
  computable without it.
- **`unique_clicks`** — present in paid staging, absent from the mart, and **structurally
  empty**: all three derived flows hardcode `toInt64(0)`, and no table in either live
  `raw_fb_ads_*` database has any column containing "unique". Meta exposes it, but it was
  never selected in the Fivetran report Fields config. Out of scope.

### "3 seconds views" — resolved, no work needed for Meta

**Meta's 3-second view already ships, under the name `video_views`.** Meta defines
`post_video_views` as *"played for at least 3 seconds, or nearly its total length if
shorter"*, and `facebook_pages.yaml` maps it to mart `video_views`. On the paid side the
`video_view` action type is the same metric. Instagram's `views` (post-April-2025) is also
3-second-gated for organic.

A cross-platform 3-second column **cannot exist**:

| platform | what its view metric counts |
|---|---|
| Meta / FB Pages | ≥ 3 seconds |
| Instagram | ≥ 3s organic; any duration when boosted |
| TikTok organic | 0 seconds (impression-like) |
| TikTok Ads | nearest gate is `video_watched_6_s` — 6 seconds |
| YouTube | `engaged_views` — approximately 10 seconds |

Summing them would add 3s + 0s + 6s + 10s counts.

**"Avg. views"** is not a column and per-post degenerates to `video_views` itself. As a
table-footer aggregate it is `sum(video_views) / post_count`, computable web-side through the
existing `totalsCompute` hook — pending confirmation that this is the intended reading.

### Migration

```sql
ALTER TABLE frnd_agg_marts.social_content_performance
    ADD COLUMN IF NOT EXISTS `duration_seconds` Nullable(Int64) AFTER `video_views`;
```

Metadata-only, O(1) in table size, table stays readable and writable. Modelled on
`v2/018_add_clicks_to_social_content_performance.sql`, which performed the identical
operation on the identical table in July 2026. **Ordering: DDL first, transformer second.**

## API Endpoints

### `GET /api/v1/paid/performance` — modified

`platform_performance[*]` gains:

| field | type | formula |
|---|---|---|
| `cpl` | float | `sum(cost) / NULLIF(sum(leads), 0)` |
| `frequency` | float | `sum(impressions) / NULLIF(sum(reach), 0)` |
| `thruplays` | int | `sum(thruplays)` |
| `link_clicks` | int | `sum(link_clicks)` |
| `cost_per_thruplay` | float | `sum(cost) / NULLIF(sum(thruplays), 0)` |

`summary_performance.consideration` gains `cpl`.

Changed values: `cpm` → `sum(cost)*1000/NULLIF(sum(impressions),0)`;
`cpp` → `sum(cost)/NULLIF(sum(purchase_count),0)`.

Unchanged and deliberately untouched: `cpv` (ledger conflict M1).

### `GET /api/v1/owned/posts` — modified

`data[*].metrics` gains `video_views` (int) and `engagement` (int). `views` is unchanged and
still equals impressions.

### `GET /api/v1/paid/detail` — unchanged

The `cost_per_unique_click` → `cost_per_link_click` rename was **cut** (see FR-8). No field
name changes anywhere in this feature, so **the three PRs are independently mergeable** — no
lockstep, no merge order, no cache flush.

## Acceptance Criteria

Testing is opt-in in this repo (`data-service/AGENTS.md` top banner) and has not been
requested, so verification is by running the services and comparing responses.

- **AC-1** — `/paid/performance` returns `cpl`, `frequency`, `thruplays`, `link_clicks`,
  `cost_per_thruplay` on every platform row, for workspace `01jzmezcgv32fvz49abwmyaems`.
- **AC-2** — `cpl` from `/paid/performance` matches `cpl` from `/paid/detail`
  (`campaign_performance_detail.py:201`, an independent code path) for the same window.
- **AC-3** — a before/after table of `cpm` and `cpp` per funnel × platform is captured and
  included in the PR body.
- **AC-4** — `/owned/posts` returns non-zero `video_views` for Instagram and TikTok rows.
- **AC-5** — `/owned/posts` still returns `clicks: null` for non-Facebook platforms. Null
  means "this platform does not report clicks" and must never become 0.
- **AC-6** — no endpoint reads `pap.cost_per_leads`, `pap.leads_rate`, `pap.cpm`, `pap.ctr`
  or any `cost_per_*` mart column.
- **AC-7** — grepping for `cost_per_link_click` / `costPerLinkClicks` returns **no hits** in
  any repo (the rename was cut; only explanatory comments name it). `cost_per_unique_click`
  is present and unchanged.
- **AC-8** — the ER column is still visible in the owned Compare modal after the new column
  is added (it is dropped silently if inserted before position 7).
- **AC-9** — `system.columns` shows `duration_seconds` on `social_content_performance` after
  the human-run migration, and existing rows read NULL.
- **AC-10** — ledger rows N1–N6 exist, and none of them reuse the labels M1 or M2.

## Open Questions

1. **"Avg. views"** — confirm with the requester that the intended reading is the
   table-footer aggregate `sum(video_views) / post_count` rather than a per-post value
   (which would just be `video_views`).
2. **FR-4 / FR-5 disclosure** — CPM and CPP change by 30–255×. The requester should be told
   before merge, since it will read as a regression to anyone who trusted the old figure.
3. **Ledger conflicts M1 (`cpv`) and M2 (owned ER)** remain open and unowned. `OUT-019`
   cannot be closed in full until they are answered. Not this feature's to settle.
4. **Meta lead action types** — the transform pivots `action_type = 'lead'` exactly. Meta
   emits seven overlapping lead types, all equal on the sampled brand, but a brand running
   Lead Ads instant forms would report under `onsite_conversion.lead_grouped`. Worth a
   follow-up ticket against `frnd-orchestration`.
5. **`frnd-orchestration` sequencing** — its 29 staged observatory files must be committed
   or parked, and the `v2/021` ALTER applied, before FR-9's projection can land.
