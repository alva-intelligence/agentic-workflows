---
title: Campaign creation filter — ATL and Earned media
slug: campaign-filter-atl-earned
author: fahmi
created: 2026-08-23
status: draft
services: [web, api]
branch: improvement/fahmi/vc-campaign-filter-atl-earned
---

# Campaign creation filter — ATL and Earned media

> **Provenance.** Brainstorming for this feature ran to completion in an opencode session on
> 2026-08-23 (`ses_fd2406744ffeenffkjjVfQuPok`, 15:32–16:50). All three question rounds were
> asked and answered; the harness then aborted every `write` call, so the PRD was never
> persisted. This document reconstructs it from that session's transcript. The eleven
> decisions in §Decisions are quoted from the recorded answers, not re-derived. Every file
> anchor was **re-verified against the working tree on 2026-08-23** before being written here.

## Overview

Campaign creation filters ATL and Earned media incorrectly. Paid and Owned are first-class
throughout the wizard — they auto-skip when unscoped, they gate Continue, they resolve to the
right step from the dashboard — while ATL and Earned are half-wired: ATL is missing from the
`MediaType` union entirely, neither channel auto-skips, ATL can never gate a step, and the
dashboard's "Configure ATL" CTA routes into a dead end that tells the user to go back.

**Ticket** (given by Fahmi directly; not found in the mirrored Lark tasklist):

- *Description:* "Currently the filter only works for Paid and Owned while the ATL and Earned
  media still have some unfinished work"
- *Definition of Done:* "To enable proper filtering of ATL and Earned Media during campaign
  creation and ensure they are displayed correctly in the campaign dashboard."

**Naming, because it is load-bearing:** in this codebase a "Campaign" **is** a `CustomReport`.
Creation is `ReportWizard.tsx` (its on-screen title is literally "Create New Campaign"), the
dashboard is `ReportView.tsx`, and the backend model is `Report` on the `reports` table with
everything media-typed living inside one JSON `spec` column
(`api/database/migrations/2026_05_12_000001_create_reports_table.php:11-27`).

Audience: brand and agency users creating campaigns and reading campaign dashboards.

### What this is NOT

The ATL and Earned **backend is already built and correct.** Query builders
(`build_atl_clause` at `data-service/app/api/repositories/reports/query.py:424`,
`build_earned_clause` at `:350`), shapers (`_shape_atl` at
`data-service/app/api/repositories/reports/shaper.py:1058`), metadata endpoints
(`/atl-metadata` at `data-service/app/api/v1/reports.py:1210`, `/earned-metadata` at ~`:1017`),
and Laravel spec validation (`api/app/Http/Requests/Report/Concerns/ValidatesReportSpec.php:139-191`)
are all present and working. This feature is a **wizard-gating and dashboard-display** fix.
Split is roughly **85% web, 15% api, 0% data-service.**

## Brainstorming Outcome

Two `@explore` subagents surveyed web and backend and returned 20 and 10 numbered gaps
respectively. The main thread then verified the load-bearing claims itself, and **corrected one
of them**, which materially changed the shape of the work:

**Corrected — the "ATL discriminator split" is false.** The backend explore agent reported that
`atl_media_performance` carries two competing media discriminators (`placement_type` at
`012_create_atl_media_performance.sql:18` and `media` at `:49`), that report filters read
`placement_type` while canonical ingest populates `media`, and that ATL filters therefore return
nothing — which would have made this a data-service ticket and matched the symptom
"filter only works for Paid and Owned" exactly.

It does not hold. `orchestration/tasks/load_marts.py:1436` writes
`ifNull(s.media, '') AS placement_type` and `:1481` writes `nullIf(s.media, '') AS media` —
**both projected from the same staging column `s.media`**, i.e. dual-written, not divergent.
The rename is documented in that file's own docstring at `:1266`
(*"Static renames … `placement_type` = staging `media`"*). The secondary casing concern also
fails: `build_atl_clause` lowercases the column (`query.py:446` `lower(amp.placement_type)`) and
`_bind_list` (`query.py:63`) lowercases and strips the bind side. **No data-service change is in
this feature.**

Also verified as already-correct, and therefore **not** in scope:

- `_METRIC_ROLLUP` (`data-service/app/api/repositories/reports/shaper.py:147-217`) already carries
  an `atl` key for `impressions`, `reach` and `engagement` — cross-channel KPI attribution
  includes ATL today.
- `SegmentedKpiBar` (`web/src/components/brands/reports/primitives/SegmentedKpiBar.tsx:28`) has
  `ORDER: ReportSource[] = ["paid","owned","earned","atl"]` with per-channel tones and labels —
  the KPI bar renders all four channels correctly.

### The verified gap table

Letters are the labels used throughout this PRD and in the session transcript.

| # | Gap | Anchor | In scope |
|---|---|---|---|
| **A** | `MediaType = "owned" \| "paid" \| "earned"` excludes `atl`, so `getTemplateRequirements()` can never return it and `MEDIA_LABELS` has no `atl` key (renders `undefined`) | `web/src/lib/reports/templateRequirements.ts:3,85-94,96-100` | ✅ |
| **B** | Earned/ATL filter steps never auto-skip — only `paid-filters` and `owned` do. Zero ATL sources still lands the user on the ATL filters step | `web/src/components/brands/reports/wizard/useReportWizardState.ts:133-143`, `:259-273` | ✅ |
| **C** | `validateStep` has no `atl` case; `isStepRequired` handles only `owned-channels` and `earned` | `useReportWizardState.ts:196-205`, `:207-253` | ✅ |
| **D** | `inferChannelConfigured` uses three different rules: paid/owned check selections, earned checks selections **or** filters, ATL checks filters **only** | `web/src/components/brands/reports/ReportView.tsx:126-139` | ✅ |
| **E** | `wizardStepForChannel` sends earned→`"earned"` and atl→`"atl"` — both the **filters** steps. Paid/owned go to their **sources** steps. Combined with D this is a loop: "Configure ATL" → "No ATL sources picked yet. Go back…" | `ReportView.tsx:162-173` | ✅ |
| **F** | Light Launch drops ATL 100%: `AutoScope` has no ATL member, `buildLaunchSpec` hardcodes `atlBrandSelections: []` and `atlFilters: []`, and `MEDIA_WORD` has no `atl` key. Earned is inconsistent — filters set, selections blanked | `web/src/lib/campaigns-lifecycle/launch.ts:191-203`, `:341-344`, `:360-364` | ✅ |
| **G** | api `FilterPreviewService::scopeFanOut` has no `atl` arm (`default => [[], null]`), so multi-brand ATL previews probe only the primary brand. `SpecBrandRestrictor::restrictAtlSpecToBrand` already exists at `:255`, unused | `api/app/Services/Reports/FilterPreviewService.php:490-507` | ❌ excluded |
| **H** | api never synthesises earned/ATL filters, on a comment that is now false: *"Earned + ATL have no brand-selection step in the wizard"* — both sources steps exist. With `compose_queries`' empty-array skip (`query.py:706-708`) this is a silent blank section | `api/app/Services/Reports/ReportQueryService.php:606-607` | ✅ |
| **I** | Exec-summary "ATL Placement" tile reads `sections.atl?.channelSummary` — the deprecated shape. The current shaper emits `summary`/`mediaPerformance`, so the tile falls through to a spec-derived count or `"—"` | `web/src/components/brands/reports/blocks/ExecutiveSummaryHero.tsx:69-72` | ✅ |

### Decisions

Eleven decisions, all recorded from Fahmi's answers across three question rounds. Recommended
option was taken in ten of eleven; round 1 Q4 is the exception.

**Round 1 — scope**

1. **Scope = wizard + dashboard parity.** Gaps A–E, H, I. *(Chosen over "everything incl. api
   fan-out + polish".)*
2. **Light Launch is in scope.** Gap F. LaunchDialog is a second creation path that today
   silently reports zero ATL on every campaign it creates — leaving it out would make "proper
   filtering of ATL" false on one of the two creation paths.
3. **Widen `MediaType` to include `atl`.** Not localized patches. The codebase already
   half-anticipated this with `MediaKey = MediaType | "atl"` at `templateRequirements.ts:4`;
   widening collapses that alias and makes the compiler find every site where ATL was silently
   dropped.
4. **Dashboard target = ReportView *and* the campaigns list page.** *(Fahmi chose the wider
   option over the recommended ReportView-only.)* **Now resolved to a no-op — see §Reconciliation.**

**Round 2 — mechanics**

5. **Gap B: auto-skip the FILTERS step when sources are empty, and move the required gate onto
   the SOURCES step.** Mirrors paid exactly. Rejected: skipping while leaving the required gate
   on the filters step, which would let a required template skip the very step it requires.
6. **Gap D: unify to "selections OR filters" for all four channels.** Rejected "selections only"
   because light-launch specs set filters without selections and would render as unconfigured.
7. **Gap F: gate ATL on a connected ATL sheet.** Pass an `atlConnected` boolean into `autoScope`,
   derived the same way `paidPlatforms` already is at `LaunchDialog.tsx:151`. Rejected emitting
   ATL unconditionally (dishonest on brands with no sheet) and gating on the plan's allocation
   (a campaign tracked without a plan would never get ATL).
8. **Gap F: backfill `earnedBrandSelections` and `atlBrandSelections`, not just the filters.**
   Today `earnedBrandSelections: []` ships alongside a populated `earnedFilters`, so re-opening a
   light-launched campaign in the wizard shows "No earned sources picked yet" despite live
   filters. Backfilling makes light-launch specs round-trip.

**Round 3 — display and blast radius**

9. **Gap I: sum `placementCount` from `mediaPerformance`,** keeping the spec-derived fallback for
   when the section is absent. Verified buildable: `shaper.py:1098` aggregates
   `placement_count=("publisher","nunique")` and the field is already typed as
   `AtlMediaPerformanceRow.placementCount` at `web/src/types/brands/custom-report.ts:629`.
10. **Template policies stay unchanged.** Widening `MediaType` adds an `atl` branch to
    `getTemplateRequirements()`, but **zero policy rows change.** ATL is `optional` or `excluded`
    in all seven templates today (`templateRequirements.ts:12-77`); marking it `required` would
    newly block Continue for every brand without an ATL Google Sheet — a behaviour change well
    outside this ticket. The branch is correctness/future-proofing and is dead code until a
    policy changes.
11. **api: fix H only, not G.** Gap G is preview-bar *accuracy* on multi-brand specs; gap H is
    *display correctness*, which is what the DoD names. G stays open — see §Deferred.

### Existing System Reconciliation

- **Decision 4 (campaigns list page) is a no-op, on evidence.** Fahmi chose the wider dashboard
  target. Checking the surface afterwards:
  `grep -n "atl\|earned\|paid\|owned\|mediaType" "web/src/app/(dashboard)/brands/[id]/insight/campaigns/page.tsx"`
  returns **zero matches**. The list page renders campaign cards with no media-type surface at
  all — there is nothing ATL/Earned on it to display correctly or incorrectly. The decision is
  therefore honoured by verifying, not by editing, and **no task is generated for it.** If the
  intent was "the list page should *start* showing per-channel badges", that is a new feature and
  needs its own ticket. Flagged in §Open Questions as Q-1.
- **`MediaType` is ambiguous across the codebase and this feature only touches one of them.**
  `web/src/types/brands/integrations.ts:3` already declares the widest union
  (`owned|paid|earned|atl|business`); the narrow one being widened here is the *separate*
  `templateRequirements.ts:3` declaration. Do not merge them — the integrations union includes
  `business`, which has no wizard step.
- **`MEDIA_LABEL` in `launch.ts:49-54` already includes `atl`**; `MEDIA_WORD` at `:360-364` does
  not. Two label maps, one file, divergent. Task W-8 aligns `MEDIA_WORD` only; the wider
  consolidation is deferred.
- **The comment being deleted in gap H documents a real past state, not a mistake.** Earned and
  ATL genuinely had no brand-selection step when it was written. `EarnedSourcesStep.tsx` and
  `AtlSourcesStep.tsx` both exist now. Replace the comment, do not just delete it.
- **`ValidatesReportSpec.php:167-169` already carries a scar from this exact class of bug** — a
  missing `atlBrandSelections` rule once caused `validated()` to strip the field, producing
  *"re-opening a saved report shows 'No ATL sources picked yet'"*. Gap F/decision 8 is the same
  symptom from a different cause. Do not regress the validation rule while touching the spec.

### Assumptions and Clarifications

- ATL and Earned are **one Google Sheet per brand**, single-platform each
  (`api/app/Models/Brand/BrandIntegration.php:189-195`: `EARNED_PLATFORMS = [google_sheets_earned]`,
  `ATL_PLATFORMS = [google_sheets_atl]`). They are structurally twins and deliberately do not
  have the platform grid that paid/owned have. Any parity work must not assume a platform list.
- Earned is **influencer/KOL data only** for now; real social-listening lands later via a
  different source (`EarnedSourcesStep.tsx:24-25`, `:152-153`, corroborated at
  `api/app/Services/Reports/FilterPreviewService.php:1068-1070`). "Earned filtering works" means
  KOL filtering works.
- `AtlSourcesStep.tsx:46-54` already gates selectability on `connectedBrandIds`, so the wizard
  path already refuses to scope ATL on an unconnected brand. Decision 7 brings Light Launch to
  the same standard rather than inventing a new rule.

## User Stories

- **US-1** — As a brand user creating a campaign, when I pick no ATL sources, I am not shown the
  ATL filters step at all, and the progress bar does not count it.
- **US-2** — As a brand user creating a campaign, when I pick ATL sources and then pick ATL
  filters, my campaign dashboard shows the ATL tab as configured with real data.
- **US-3** — As a brand user on a campaign dashboard whose ATL is unconfigured, clicking
  "Configure ATL" takes me to the ATL **sources** step where I can actually pick something,
  instead of a filters step that tells me to go back.
- **US-4** — As a brand user launching a campaign the fast way (Light Launch) on a brand with a
  connected ATL sheet, my campaign reports ATL numbers instead of silently reporting zero.
- **US-5** — As a brand user who light-launched a campaign, re-opening it in the wizard shows my
  earned and ATL sources as picked, matching the filters that are actually running.
- **US-6** — As a brand user reading an executive summary, the "ATL Placement" tile shows a real
  placement count from the data rather than `"—"`.

## Requirements

### Functional Requirements

**Type layer (gap A)**

- **FR-1** — `MediaType` in `web/src/lib/reports/templateRequirements.ts:3` becomes
  `"owned" | "paid" | "earned" | "atl"`. `MediaKey` (`:4`) collapses into it. Every resulting
  compile error is a site where ATL was silently dropped and must be resolved, not suppressed.
- **FR-2** — `getTemplateRequirements()` (`:85-94`) gains
  `if (p.atl === "required") out.push("atl");`. No policy row in `:12-77` changes (decision 10).
- **FR-3** — `MEDIA_LABELS` (`:96-100`) gains `atl: "ATL"`.

**Wizard step flow (gaps B, C)**

- **FR-4** — `isAutoSkipped` (`useReportWizardState.ts:133-143`) skips `"earned"` when
  `spec.earnedBrandSelections.length === 0`, and `"atl"` when `spec.atlBrandSelections.length === 0`,
  exactly mirroring the existing `paid-filters` and `owned` arms.
- **FR-5** — `visibleStepProgress` (`:259-273`) uses the same skip predicate, so the progress bar
  stops over-counting. It must not carry a second, drifting copy of the rule — both call the same
  helper.
- **FR-6** — `isStepRequired` (`:196-205`) moves the earned gate from `"earned"` to
  `"earned-sources"`, and gains `"atl-sources"` for `templateRequires.includes("atl")` and
  `"paid-channels"` for `paid` (decision 5). A required channel must gate the step where the user
  can actually satisfy it.
- **FR-7** — `validateStep` (`:207-253`) gains an `atl` case symmetric with the earned case, and
  its earned case moves to `earned-sources` in step with FR-6.

**Dashboard (gaps D, E)**

- **FR-8** — `inferChannelConfigured` (`ReportView.tsx:121-143`) returns
  `selections.length > 0 || filters.length > 0` for **all four** channels (decision 6). The
  `default: return true` arm for overview/highlights is unchanged.
- **FR-9** — `wizardStepForChannel` (`:162-173`) returns `"earned-sources"` for earned and
  `"atl-sources"` for atl, matching paid→`paid-channels` and owned→`owned-channels`. This is the
  fix for the CTA loop.

**Light Launch (gap F)**

- **FR-10** — `AutoScope` (`launch.ts:191-203`) gains `atlBrandSelections: AtlBrandSelection[]`
  and `atlFilters: AtlChannelFilter[]`, and `earnedBrandSelections: EarnedBrandSelection[]`. The
  interface's existing doc comment at `:193-199` — which warns that data-service skips a source
  whose filter array is empty — applies verbatim to ATL and should be extended to say so.
- **FR-11** — `autoScope()` (`:212-277`) accepts a new `atlConnected: boolean` input and emits one
  unfiltered ATL filter row when `atlConnected === true` **and** the template policy is not
  `"excluded"` (decision 7). When `atlConnected` is false it emits nothing, with no warning —
  a brand with no ATL sheet has correctly-zero ATL.
- **FR-12** — `LaunchDialog.tsx` derives `atlConnected` from a
  `useWorkspaceBrandsForReport(currentWorkspace?.id, [], "atl")` probe, mirroring the paid probe
  already at `:151` and the wizard's own gate at `AtlSourcesStep.tsx:36-40`.
- **FR-13** — `buildLaunchSpec()` (`:336-350`) sets `earnedBrandSelections`, `atlBrandSelections`
  and `atlFilters` from the scope instead of hardcoding `[]` (decision 8).
- **FR-14** — `unsatisfiedMedia()` (`:285-297`) covers ATL, and `MEDIA_WORD` (`:360-364`) gains
  `atl: "ATL"` so `launchMediaWarning()` (`:446`) stops emitting `undefined` for ATL.
- **FR-15** — `launch.test.ts:237` currently asserts the bug
  (`expect(spec.atlFilters).toEqual([])`). It is updated to assert the new behaviour on both
  branches: unfiltered ATL row when connected, empty when not.

**api (gap H)**

- **FR-16** — `ReportQueryService::synthesiseDefaultFilters` (`:612`+) synthesises an earned
  filter row per `earnedBrandSelections` entry and an ATL filter row per `atlBrandSelections`
  entry, so a wizard run that picks sources and skips the filters step queries the source instead
  of silently blanking. Follows the existing paid (`:623-649`) and owned (`:697-718`) shapes.
- **FR-17** — The stale comment at `:606-607` is replaced with an accurate one stating that
  earned/ATL selections now synthesise, and that an empty **selections** array — not an empty
  filters array — is what means "user opted out".

**Executive summary (gap I)**

- **FR-18** — `ExecutiveSummaryHero.tsx:69-72` computes `atlPlacementCount` as the sum of
  `placementCount` over `query?.sections.atl?.mediaPerformance`, falling back to the existing
  spec-derived `placements` count when the section is absent (decision 9). The
  `channelSummary` read is removed.

**Draft persistence (R-1, R-2 — found during PRD review)**

- **FR-19** — A restored draft's `step` is **clamped** before it reaches the reducer. In
  `ReportWizard.tsx:129`, if `draft.step` is `"earned"` or `"atl"` and that step is now
  auto-skipped under FR-4 (its selections array is empty), fall back to the nearest earlier
  non-skipped step rather than restoring onto a step the user can no longer be on. The draft's
  **spec is preserved untouched** — only the cursor moves. Rationale: drafts carry a 7-day TTL
  (`useReportWizardState.ts:290`), so in-flight drafts spanning this deploy are guaranteed, and
  discarding them would destroy user work over a gating change.
- **FR-20** — The draft-recovery `hasContent` check (`ReportWizard.tsx:120-125`) gains
  `draft.spec.earnedBrandSelections.length > 0` and `draft.spec.atlBrandSelections.length > 0`.
  Read defensively (`?.length ?? 0`) — legacy drafts predate both fields. Without this, a draft
  scoped only to earned or ATL is classified as empty, its recovery banner never renders, and the
  work is silently dropped at TTL.

### Non-Functional Requirements

- **NFR-1** — `npx tsc --noEmit` in `web/` must not increase the error count over its baseline.
  Capture the baseline **before** widening `MediaType`, because FR-1 is expected to raise errors
  transiently and every one of them must be fixed, not waived.
- **NFR-2** — No API field name, response shape, SQL grain, or threshold changes in this feature.
  `atlFilters`, `atlBrandSelections`, `earnedFilters`, `earnedBrandSelections` keep their names.
  The only backend edit is FR-16/17, which changes *what is sent*, not the contract's shape.
- **NFR-3** — No data-service change, no migration, no mart edit. If a task appears to need one,
  stop — that contradicts the §Brainstorming correction and needs a go/no-go.
- **NFR-4** — Existing paid and owned wizard behaviour is unchanged. The parity work generalizes
  the paid/owned rules; it must not alter them. Regression-check a paid-only and an owned-only
  campaign end to end.

## Service Breakdown

### Frontend (`web/`) — 13 tasks, merge order 2

| Task | Gap | Files |
|---|---|---|
| W-1 | A | `src/lib/reports/templateRequirements.ts` — widen `MediaType`, collapse `MediaKey`, add `atl` branch + label (FR-1..3) |
| W-2 | A | Resolve the compile fallout from W-1 across `TemplateStep.tsx:102,128,150`, `ReportWizard.tsx:235-244`, and every other `MediaType`/`MediaKey` consumer |
| W-3 | B | `useReportWizardState.ts` — `isAutoSkipped` earned/atl arms (FR-4) |
| W-4 | B | `useReportWizardState.ts` — `visibleStepProgress` shares the skip predicate (FR-5) |
| W-5 | C | `useReportWizardState.ts` — `isStepRequired` moves earned gate to sources, adds atl + paid (FR-6) |
| W-6 | C | `useReportWizardState.ts` — `validateStep` atl case, earned case moves (FR-7) |
| W-7 | D, E | `ReportView.tsx` — unify `inferChannelConfigured`, repoint `wizardStepForChannel` (FR-8, FR-9) |
| W-8 | F | `launch.ts` — `AutoScope` members, `autoScope` atlConnected arm, `buildLaunchSpec` backfill, `unsatisfiedMedia`, `MEDIA_WORD` (FR-10, 11, 13, 14) |
| W-9 | F | `LaunchDialog.tsx` — `atlConnected` probe, threaded into `autoScope` (FR-12) |
| W-10 | F | `launch.test.ts` — replace the bug-asserting test, cover both branches (FR-15) |
| W-11 | I | `ExecutiveSummaryHero.tsx` — placement count from `mediaPerformance` (FR-18) |
| W-12 | R-1 | `ReportWizard.tsx:129` — clamp a restored draft's `step` past newly auto-skipped earned/atl steps, preserving the spec (FR-19) |
| W-13 | R-2 | `ReportWizard.tsx:120-125` — `hasContent` counts earned + ATL selections (FR-20) |

### API (`api/`) — 2 tasks, merge order 1

| Task | Gap | Files |
|---|---|---|
| A-1 | H | `app/Services/Reports/ReportQueryService.php` — synthesise earned/ATL filters from brand selections (FR-16) |
| A-2 | H | `app/Services/Reports/ReportQueryService.php:606-607` — replace the stale comment (FR-17); add/extend the feature test covering a spec with earned+ATL selections and no filters |

### Data Service (`data-service/`) — **no changes**

The discriminator claim that would have put work here was disproven
(`orchestration/tasks/load_marts.py:1436,1481`). `_METRIC_ROLLUP` already carries `atl`. Do not
open a data-service task for this feature.

### AI Service (`ai-service/`) — no changes

### Orchestration (`orchestration/`) — no changes

`load_marts.py` was **read** to disprove the discriminator claim. It is not edited.

## UI/UX

No new screens, no new components, no visual design work. Every change is either invisible
(type/gating) or a correction to an existing surface:

- The ATL and Earned filters steps **disappear** from the wizard when their sources are empty.
  The step counter shrinks accordingly.
- The dashboard's "ATL isn't configured yet" / "Earned Media isn't configured yet" empty states
  (`ReportView.tsx:897-910`) appear in strictly fewer cases after FR-8, and their CTA lands
  somewhere useful after FR-9.
- The exec-summary "ATL Placement" tile stops showing `"—"` on campaigns that have ATL data.

## Data Model

No new tables. No modified tables. No migrations. The `reports.spec` JSON column already carries
`atlBrandSelections` / `atlFilters` / `earnedBrandSelections` / `earnedFilters`
(`web/src/types/brands/custom-report.ts:355-376`), and `ValidatesReportSpec.php:139-191` already
validates all four.

## API Endpoints

No new endpoints, no changed signatures. `POST /v1/reports/query` behaves differently in one
respect only: a spec carrying earned/ATL **selections** with empty **filters** now produces
synthesised filters server-side (FR-16) instead of an omitted section.

## Acceptance Criteria

- [ ] **AC-1:** In the wizard, selecting zero ATL sources means the ATL filters step is never
      shown and the progress total decreases by one. Same for earned.
- [ ] **AC-2:** Selecting one or more ATL sources shows the ATL filters step, and Continue is
      gated by `validateStep`'s new `atl` case.
- [ ] **AC-3:** On a campaign dashboard where ATL sources were picked but the filters step was
      skipped, the ATL tab renders as **configured** (not the empty state).
- [ ] **AC-4:** Clicking "Configure ATL" on an unconfigured ATL tab opens the wizard at the ATL
      **sources** step. The "No ATL sources picked yet. Go back…" dead end is unreachable from
      that CTA. Same for "Configure Earned Media".
- [ ] **AC-5:** Light-launching a campaign on a brand **with** a connected ATL sheet produces a
      spec with a non-empty `atlFilters` and a populated `atlBrandSelections`.
- [ ] **AC-6:** Light-launching on a brand **without** an ATL sheet produces empty `atlFilters`
      and emits no ATL warning.
- [ ] **AC-7:** A light-launched campaign re-opened in the wizard shows its earned and ATL sources
      as picked (not "No earned sources picked yet").
- [ ] **AC-8:** `launchMediaWarning()` never emits the string `undefined` for any of the four
      media types.
- [ ] **AC-9:** A saved spec with `atlBrandSelections` populated and `atlFilters: []` returns a
      populated ATL section from `POST /v1/reports/query` rather than an omitted one. Same for
      earned.
- [ ] **AC-10:** The exec-summary "ATL Placement" tile shows the summed `placementCount` on a
      campaign with ATL data, and the spec-derived fallback when `sections.atl` is absent. It
      never reads `channelSummary`.
- [ ] **AC-11:** Regression — a paid-only campaign and an owned-only campaign create, save,
      re-open and render exactly as before this feature.
- [ ] **AC-15:** A draft saved on the `"earned"` or `"atl"` step with empty selections, then
      restored after this ships, opens on a valid earlier step with its spec fully intact — not on
      a step that is now auto-skipped, and with nothing lost (FR-19).
- [ ] **AC-16:** A draft whose only content is ATL sources (no name, no template, no KPIs, no
      paid/owned) surfaces the draft-recovery banner on return (FR-20).
- [ ] **AC-12:** `npx tsc --noEmit` in `web/` does not increase the error count over the baseline
      captured before W-1 (NFR-1). Record both numbers in the PR.
- [ ] **AC-13:** No file under `data-service/` or `orchestration/` is modified by this branch.
- [ ] **AC-14:** `docs/DECISIONS-LEDGER.md` carries a row for the PRD reconstruction and a row for
      the disproven discriminator claim.

## Open Questions

- [ ] **Q-1:** Decision 4 asked for the campaigns list page to be included, but that page has zero
      media-type references and nothing to fix. Should the list page **gain** per-channel badges
      showing which of the four media types a campaign is scoped to? That is net-new UI and is
      currently out of scope. **Needs a yes/no from Fahmi** — if yes, it is a separate ticket.
- [ ] **Q-2:** FR-2 adds an `atl` branch to `getTemplateRequirements()` that no template can
      currently trigger (decision 10 froze the policies). Is the dead branch acceptable as
      future-proofing, or should ATL become `required` on some template in a follow-up?
- [x] **Q-3 — ANSWERED, and the risk is real. The wizard DOES persist step position.**
      `writeDraft` serialises `{ step, spec, savedAt }` (`useReportWizardState.ts:329-343`) into
      `localStorage` under `frnd:campaign-wizard-draft:<brandId>` with a **7-day TTL** (`:290`),
      and `ReportWizard.tsx:129` restores it verbatim: `step: (stepFromUrl ?? draft.step)`.
      So a user who was mid-wizard on `"earned"` when this ships resumes **onto that exact step**,
      now under FR-6/FR-7's changed gating. Mitigation is specified as FR-19 — no new question.

## Resolved during PRD review

- **R-1 (was Q-3): stale drafts can resume onto a re-gated step.** See FR-19. Chosen fix is the
  cheap, non-destructive one: keep the draft's spec, clamp only its `step`. Discarding drafts
  outright would throw away user work for a gating change they will not even notice.
- **R-2: the draft-recovery banner is blind to earned/ATL-only drafts.** Found while answering
  Q-3. `ReportWizard.tsx:120-125` decides a draft `hasContent` from `name`, `templateId`, `kpis`,
  `ownedBrandSelections` and `paidBrandSelections` — **earned and ATL selections are not
  checked.** A user who picked only ATL sources and closed the tab is told nothing on return and
  silently loses the draft after 7 days. This is the same paid/owned-only omission the whole
  ticket is about, on a surface neither explore pass reached. Folded in as FR-20.

## Deferred — found while drilling, NOT in this feature

Recorded so nobody re-derives them. None of these are regressions introduced here.

1. **Gap G — api ATL fan-out.** `FilterPreviewService::scopeFanOut` (`:490-507`) has no `atl` arm,
   so multi-brand ATL specs preview only the primary brand.
   `SpecBrandRestrictor::restrictAtlSpecToBrand` (`:255`) already exists and is unused; a
   `loadAccessibleAtlBrands` mirroring `:665` would complete it. Explicitly excluded by decision 11.
2. **`ensureScopeHasFilter` asymmetry.** `FilterPreviewService.php:772-826` has only `paid` and
   `owned` branches — the preview-side twin of gap H.
   > ✅ **PULLED INTO THIS BRANCH** 2026-08-23 at Fahmi's request after live evidence — see
   > `docs/DECISIONS-LEDGER.md` `W7a`. Gap G (item 1) remains deferred; decision 11 stands.
3. **`QuickEditPopover` ATL/earned undercounts.** `:195-202` counts `atlFilters.length` (groups)
   without brands, unlike paid/owned/earned at `:152-193`; `:182-185` sums only earned `sources`
   and `keywords`, ignoring `platforms`, `campaignNames`, `namaKol`, `contentFormats`, `personas`.
4. **`AtlSectionData` has its optionality inverted.** `custom-report.ts:651-666` — deprecated
   `channelEngagement` and `channelSummary` are **required** while the current fields
   (`summary`, `mediaPerformance`, `budgetRecap`, `weeklyReach`, `grpsByStation`, `:669-675`) are
   all optional. FR-18 removes the last read of `channelSummary` in the exec summary but does not
   fix the type.
5. **Legacy `medium` field has no read-side migration.** `custom-report.ts:261-273` deprecates
   `medium` for `mediums[]`; `AtlFiltersStep.tsx` writes only `mediums`. Owned has
   `normalizeOwnedFilters` (`useReportWizardState.ts:183`); ATL has no equivalent, so a
   pre-migration saved spec loses its medium.
6. **Earned platform whitelist blocks non-social earned rows.**
   `data-service/app/api/repositories/campaign/taxonomy.py:94` hardcodes
   `IN ('youtube','instagram','facebook','tiktok','x')`; report earned filters
   (`query.py:379-382`) do not. Only matters once earned stops being KOL-only.
7. **ATL/earned campaign endpoints ignore the account filter.**
   `data-service/app/api/v1/campaign.py:134-159` — neither declares `username_filter`; also
   `api/app/Http/Middleware/ApplyDashboardAccountFilter.php:54-60` maps `campaign` to
   `['owned','paid']` only, by documented intent.
8. **`campaign_performance` existence gate on ATL/earned.**
   `campaign/atl_performance.py:36-50` and `campaign/earned_performance.py:41-56` return empty
   when the rollup is empty — the same bug class already fixed for the taxonomy spine and
   documented at `campaign/taxonomy.py:126-136`.
9. **`CampaignCreationModal.tsx` is unreachable dead code** whose "Data Filters" tab is a
   `"coming soon"` stub (`:253-255`) — i.e. an abandoned second take on this exact surface.
   `setIsCampaignCreationModalOpen` is never called with `true`
   (`BrandInsightLayoutWrapper.tsx:243,1817-1820`). Delete-or-wire is its own decision.
10. **`campaign_actuals.channel` is validated in data-service but not api.**
    `SubmitCampaignActualsRequest.php:52` accepts any string; `ChannelKey`
    (`data-service/app/api/schemas/campaigns.py:50-59`) is a closed 8-value `Literal`. A bad ATL
    channel persists to Postgres then 422s at ingest
    (`IngestCampaignActualsJob.php:107`: *"Permanent failure — rows remain in Postgres only."*).
11. **No shared `MediaType` enum in api.** The four media types are hardcoded in at least four
    places: `BrandIntegration.php:110-121`, `FilterPreviewRequest.php:71`,
    `WorkspaceBrandsController.php:79`, `BrandIntegrationController.php:49-55,1445-1449`.
12. **Earned `platforms` and ATL `mediums` are unvalidated free strings.**
    `ValidatesReportSpec.php:146,181` — only the legacy singular fields carry `Rule::in`.
13. **ATL cardinality is uncapped.** `query.py:654-674` caps paid `adAccountIds` (50) and earned
    `keywords` (200); `atlFilters.placements`, `campaignNames` and `cities` have no cap.
14. **`_shape_atl` is TV-biased and ATL is missing from highlight scoring.**
    `shaper.py:1229-1230` breaks down only `placement_type == "tv"`; `:1497` `sources` dict has no
    `atl` key. Also `:1096` falls back to `("reach","size")` for GRPs — a row count presented as
    GRPs.
15. **Stub template still ships four deprecated ATL/Earned blocks.**
    `stubReportTemplates.ts:82-100`; all four are stripped at runtime by
    `ReportView.tsx:349-353,382-385`.
16. **`web/docs/prd/earned-atl-google-sheets.md` has TASK-1…TASK-16 all unchecked**, including
    TASK-11 (`KpiSetupComingSoon.tsx` empty state for earned + atl). That PRD predates this one
    and overlaps it; it should be reconciled or banner-superseded rather than left readable as
    live work.
