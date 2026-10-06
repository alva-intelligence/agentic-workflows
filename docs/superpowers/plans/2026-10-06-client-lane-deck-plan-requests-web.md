# Client Lane — Deck and Campaign Plan on Approval Requests — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decks and campaign plans use the same approval-request flow KV uses on the web. The agency gets one set of components: a top-bar slot, a Share-dialog section, a status list and a request form, all keyed by subject. Those components are mounted in the deck top bar and Share dialog, a new plan-view header, `SharePlanDialog` and a flag-gated lifecycle menu. On the client side, `/s/[token]` serves deck and plan requests as one card. The card uses one pins/decision rule for all three types, a 6-digit code sheet, a text-only fallback and a downloadable approval record.

**Architecture:** Pure modules own every rule, and components only wire:

- `lib/client-lane/subjectRequests.ts`: agency copy, slot state, disabled reasons, item lines, record filenames;
- `lib/client-lane/requestDecision.ts`: client page entries, button labels, decision step, headline, hero choice, record availability;
- `lib/client-lane/drain.ts`: whether a P0a round is still pending;
- `lib/client-lane/planDecisions.ts`: the rows of the plan "Decisions" block;
- `lib/campaigns-lifecycle/approvalMenu.ts`: which approval items the lifecycle row menu offers.

The four KV agency components become generic. Each takes `subject: ApprovalSubject` (`git mv` plus edits), and the KV call sites only swap imports and props. Service hooks take `(subjectType, subjectId)`. The client page keeps its KV request branch untouched and adds a `RequestEntry` model for one-item deck/plan requests. Those requests render through a new `RequestHero` dispatcher (deck → `DeckHero`, plan → `PlanHero`, otherwise a text card) and the existing rail.

**Tech Stack:** Next.js 16 app router, React 19, TypeScript, Tailwind 3.4, TanStack Query v5, `@base-ui/react` (frndOS v2), Radix (`BaseModal`), PostHog (`posthog-js`), `bun test` (vitest-compatible API, jsdom preload), Testing Library.

**Spec:** `docs/superpowers/specs/2026-10-06-client-lane-deck-plan-approval-requests-design.md` (workspace root). This plan implements the web half:

- §5 (agency) and §6 (client page);
- §7.1 phases 4–7;
- §7.2 drain behaviour on the web;
- the §8 web tests and manual checklist.

Open question 3 is decided. A manual plan status change closes an open request's pending plan approval. That is api work: the web only re-reads requests after the change (Task 11). Predecessor: `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md` §11 (frndOS components first), which binds every UI task here.

## API contract assumed

> **Reconciled with the api plan (2026-10-06).** `2026-10-06-client-lane-deck-plan-requests-api.md` § "API contract for web" is authoritative. Differences found and settled:
> - Preview items: `round` is always present; `version_id` is `null` for a deck before sending; `blocked_reason` is always present (`null` or `"no_brand"`). The types below are updated; every test fixture built with `requestPreview(...)` must give items a `round` and may give deck items `version_id: null`.
> - Brand-less send: the api answers `422 { code: "no_brand", message, errors.subject_id }`. The `err.code === "no_brand"` branch is correct.
> - Public deck/plan request payload: `items` is **populated** (one entry with `snapshot.kind` `"deck"`/`"campaign"`), not `[]`. Request-link code reads `approvals[]`, never `items`. The `deckRequestLink`/`planRequestLink` fixtures keep `items: []`, which is harmless, but no request-link code may branch on `items.length`.
> - `approvals[].fingerprint` is a string for deck/plan too (the web ignores it). Nullable types stay.
> - The public `record.pdf` also serves withdrawn requests. The web shows the client button only for decided requests (ruling 6), a subset, which is fine.
> - Magic links are refused for request links (api S13). `VerifySheet` must never mount on a request link, as Task 15 already does.
> - Contract notes: api Task 14 appends to `api/docs/prd/client-lane-p0a/api.md`. Web Task 17 copies the same block byte-identically into `web/docs/prd/client-lane-p0a/web.md` and diffs the two files.


The api plan is being written in parallel. The web codes against the shapes below. Any field marked **(assumed)** is a web reading of the spec that the two plans must reconcile before Task 1 merges. Everything not listed keeps the KV request contract from 2026-10-01 unchanged.

**Endpoints (agency, `axiosInstance`, authenticated):**

| Call | Params / body | Answer |
|---|---|---|
| `GET v1/approval-requests/preview` | `subject_type` ∈ `kv_file`, `deck`, `campaign`; `subject_id` | `{ data: ApprovalRequestPreview }` |
| `GET v1/approval-requests` | same | `{ data: AgencyRequest[] }` (open first, then newest) |
| `POST v1/approval-requests` | `{ subject_type, subject_id, approver_emails, message?, decide_by?, kv_phases? }` — `kv_phases` only for `kv_file` | `{ data: { request, share_url, approvers } }`; `422 no_brand` for a brand-less subject; `422 nothing_ready`; `409 round_conflict` |
| `POST v1/approval-requests/{id}/withdraw` / `/resend` | — | unchanged |
| `GET v1/approval-requests/{id}/record.pdf` | — | `application/pdf` body, any status |

**Endpoints (public, `axiosPublic`, `X-Lane-Code` when held):**

| Call | Answer |
|---|---|
| `GET public/share-links/{token}` on a deck/plan request link | `ShareLinkDeck` / `ShareLinkCampaign` with `request` + `approvals[]` set, `approval: null`, `items: []`, `version: { type: "approval_request", label: "Request {n}", … }`. `document` is the frozen render source of `approvals[0].version_id` (deck: the frozen `DeckDocument`, plus `deck: { theme, slide_themes, play_settings }`; plan: the `PublicPlan` projection) — the same keys the round branch sends. **(assumed: same keys as the round branch)** |
| `POST public/share-links/{token}/decision` | unchanged request-link C-3 (`approval_ids`, `outcome` ∈ `approved` / `changes_required` / `deferred`, `note`, `pins`). The api stores `approved` + pins on that version as `approved_with_changes` (KV behaviour). `403 verification_required` for a deck/plan decision without a lane. |
| `GET public/share-links/{token}/record.pdf` | `application/pdf`; `404` until the request is `complete` or `withdrawn` |

**TypeScript after Task 1 (`src/services/client-lane.ts`):**

```ts
export interface AgencyRequestApproval {
  id: string;
  /** null for deck / plan — one item, no artboard key. */
  subject_key: string | null;
  /** null for deck / plan. */
  phase: KvSharePhase | null;
  /** "Deck" / "Campaign plan" for deck / plan. */
  label: string;
  /** Deck: continues from its P0a rounds (v3 → v4). */
  round: number;
  version_id: string;
  thumbnail_url: string | null;
  /** null for deck / plan (no composite to upload). */
  fingerprint: string | null;
  /** KV only; deck / plan code never reads it. */
  snapshot: PublicKvItem | null;
  status: ApprovalStatus;
  superseded_by_request_number: number | null;
  pin_count: number;
  decisions: ApprovalDecision[];
}

export interface ApprovalRequestPreviewItem {
  subject_key: string | null;
  phase: KvSharePhase | null;
  label: string;
  /** null for a deck before sending — the version row is minted by the send (api S5). */
  version_id: string | null;
  thumbnail_url: string | null;
  fingerprint: string | null;
  snapshot: PublicKvItem | null;
  /** The round this send would freeze (the "v4"). Present for every type (api S5). */
  round: number;
  /** `request_number: null` = it replaces a pending P0a round (drain). (assumed) */
  replaces: { request_number: number | null; round: number } | null;
}

export interface ApprovalRequestPreview {
  /** `[]` for deck / plan. */
  phases: Array<{ phase: KvSharePhase; count: number }>;
  items: ApprovalRequestPreviewItem[];
  already_approved: Array<{
    subject_key: string | null;
    phase: KvSharePhase | null;
    label: string;
    version_id: string | null;
  }>;
  waiting: Array<{
    subject_key: string | null;
    phase: KvSharePhase | null;
    label: string;
    version_id: string | null;
    request_number: number;
  }>;
  /** Deck / plan: 1 when the current version is neither approved nor waiting. */
  total: number;
  /** Always present: null, or "no_brand" when the subject cannot be sent. */
  blocked_reason: "no_brand" | null;
}

export interface CreateApprovalRequestInput {
  /** kv_file only — omitted for deck / plan. */
  kv_phases?: KvSharePhase[];
  approver_emails: string[];
  message?: string;
  decide_by?: string;
}
```

Public type (`src/lib/client-lane/types.ts`): `PublicRequestApproval.phase` becomes `KvSharePhase | null` (null on deck/plan). No other public type changes.

---

## Global Constraints

- **Where to work:** worktree **WT** = `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-deck-plan-requests` on branch `feature/daffa/vc-client-lane-deck-plan-requests`, cut from the latest `origin/develop` (Task 0). Agent shells reset cwd, so every command starts with `cd` to that literal path. `cd WT` in the steps below means exactly that path. Never write in `web/` itself. Daffa may be live-testing there (memory: no write agents during live testing).
- **Git:** use `/usr/bin/git` and `/usr/bin/grep` (an rtk hook rewrites plain `git`/`grep` output). The shell is zsh: put file lists in arrays (`F=(a b); npx eslint "${F[@]}"`) and quote globs. Commit with `/usr/bin/git commit -F - <<'EOF' … EOF`, subject `<type>(web): …`, last line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. **Never push. Never `git stash`.** Never open a PR.
- **Tests:**
  - Run `bun test <file>` with ONE file per invocation. Never pass a directory (memory: a directory run blew up to 26 GB), never `bunx vitest`.
  - Query with `within(document.body)` (`const body = () => within(document.body)`), never `screen`.
  - Import `"@testing-library/jest-dom/vitest"` at the top of component tests.
  - Every test file stays **< 45 KB**: check `wc -c` before adding to an existing file. bun dies past ~51 KB with a bogus SCSS error.
  - Read bun's `N error` line, because a file that dies at import shows as one error, not as failures.
  - bun has no `vi.hoisted`, `vi.mocked` or `vi.waitFor`. Use RTL `waitFor` and cast spies.
- **Mocks:** **never `vi.mock` / `mock.module` a module** (bun's registry is process-global and binds once). Spy on the edges:
  - `vi.spyOn(axiosInstance, "get" | "post")` (`import axiosInstance from "@/services/axios"`);
  - `vi.spyOn(axiosPublic, …)` (`import { axiosPublic } from "@/services/axios"`);
  - `vi.spyOn(posthog, "capture")` (`import posthog from "posthog-js"`);
  - `vi.spyOn(globalThis, "fetch")`.

  Call `vi.restoreAllMocks()` in `beforeEach`. Existing suites register partial module mocks (`KvSharePanel.test.tsx`: `@/lib/featureFlags`, `@/store/useToast`, `@/lib/analytics/kv-generator-events`; `SharePlanDialog.test.tsx`: `@/lib/featureFlags` → `useClientLaneEnabled` only; `SavedPlansList.test.tsx`: `PlanDecisionsBlock`). Therefore:
  - every generic component in `src/components/client-lane/agency/` imports nothing from `@/lib/featureFlags` and nothing from `@/lib/analytics/kv-generator-events`;
  - those components read toasts only as `useToastStore((s) => s.showToast)`;
  - hosts gate the flag and pass the result down.
- **Every new test proves itself (memory: plan tests written from reasoning were vacuous 6×):**
  - Watch it FAIL for the stated reason before implementing.
  - Recompute every expected value from the real code, not from this plan.
  - After it passes, apply the **named mutation**, watch the named test fail, restore, and watch it pass.
  - If an expectation disagrees with code that matches the spec, fix the expectation and note it in the track's session log.
- **Type gate:**
  - `npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"` must stay ≤ the baseline recorded in Task 0.
  - `npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "<touched paths>"` must show no NEW lines. Per-file baselines are in the track; `KvGeneratorLayout.tsx` and `KvMotionEditor.tsx` carry one pre-existing error each.
  - The build does not type-check (`ignoreBuildErrors`).
- **Lint / format:**
  - `npx eslint <touched files>` must report 0 errors and no new warnings on changed lines.
  - Run `bunx prettier --write` only on files whose `origin/develop` version is already prettier-clean. Check with `/usr/bin/git show origin/develop:<path> | bunx prettier --check --stdin-filepath <path>`. Hand-format the others: memory records a formatter-churn finding against the PR size.
- **frndOS components first (KV spec §11):**
  - Before any UI task, read `WT/.claude/skills/frndos-ui/SKILL.md`, then `frndos-components-v2`, `frndos-design-foundations` (Appearance tri-mode) and `frndos-rules`.
  - Component priority: v2 → v1 → base → new v2 component. No new v2 component is planned here.
  - One NEW file never imports both `@/components/frndos` (v1) and `@/components/frndos/v2`. Existing mixed files (`DeckShareLinks.tsx`, `SharePlanDialog.tsx`) keep their mix and gain nothing new from v1.
- **Tokens only** on every line this plan writes or rewrites:
  - text `text-text-inverse`, `text-text-inverse-subtle`, `text-text-inverse-subtlest`;
  - sizes `text-textXs`, `text-textXsMedium`, `text-textSm`, `text-textSmMedium`;
  - radius `rounded-full`, `-2xl`, `-xl`, `-lg`, `-md`;
  - surfaces `bg-white/5`, `/10`, `/15` or `bg-surface-*`;
  - borders `border-white/10`, hairlines `border-white/5`;
  - `font-geist`, `transition-all duration-200 ease-out`, `focus-visible:ring-2 focus-visible:ring-white/40`.

  Never use `text-[Npx]`, `rounded-[Npx]`, `px-[Npx]`, `text-white`, `text-gray-*`, an arbitrary `white/[0.0x]` opacity or a new dark hex (memory: dark hex is invisible to the Aurora sweep). Agency UI must read right in **Midnight, Aurora and Daylight**. The public `/s/` page stays dark-scoped (`data-theme-scope="dark"`, #754).
- **Copy** (spec §5–§6, exact strings):
  - "artboard(s)" appears only for `kv_file`.
  - The client buttons are:
    - "Approve deck", "Approve plan", or "Approve" (KV, per artboard);
    - "Request changes" (no pins);
    - "Send 1 pin as changes" or "Send N pins as changes".
  - The brand-less reason is "Link this deck to a brand to request approval".
  - The client record button is "Download approval record".
- **Drain (spec §7.2):** the new web never calls `createApproval` / `v1/approvals` POST for a new deck or plan request. P0a rounds stay readable, withdrawable and resendable through `ApprovalStatusBlock` while one is pending. Old round links keep the round branch, `VerifySheet` and `HowBigSheet`.
- **Toasts:** `useToastStore((s) => s.showToast)(title, description, type)`.
- **Analytics:** only through typed helpers in `src/lib/analytics/client-lane-events.ts`, never an inline `posthog.capture`. Analytics is part of the feature (memory). Every new or changed event is listed for the Lark taxonomy in the final task.
- **Flag:** everything agency-side sits behind `show-client-lane` (`useClientLaneEnabled()` in hosts). `/s/*` is unflagged.

## Review Focus

Five inputs the spec implies but no happy path exercises, most likely to bite first. Each has a named test in its owning task.

1. **A brand-less deck.** Today the Request button 422s. Both the top-bar slot and the Share-dialog section must show a disabled button with the words "Link this deck to a brand to request approval". The words must be readable, not hover-only, in the dialog. → Task 2 (`requestBlockedReason`, `subjectSlotState` "disables it with the reason on a brand-less deck"), Task 5 ("disables Request approval on a brand-less deck and says why"), Task 6 ("disables the deck button and carries the reason").
2. **A deck with a pending P0a round when the agency sends a request.**
   - The P0a block shows while the round is pending and disappears once that round is no longer the newest pending one.
   - The new form never posts to `v1/approvals`.

   → Task 7 (`pendingRoundOf`: "is null once the newest round is closed"), Task 4 ("sends a deck request without kv_phases"; it asserts the URL is `v1/approval-requests`).
3. **Pins from this visit vs. pins on the item.**
   - "Send N pins as changes" counts only THIS viewer's pins from this visit on THAT item's version.
   - Approve with pins carries them, so the api stores `approved_with_changes`.
   - Request changes with zero pins must ask for a note.

   → Task 12 (`decisionStep` tests), Task 15 ("labels the second button by this visit's pins on the focused artboard").
4. **Floating UI inside a Radix `BaseModal`.**
   - Base UI popovers portal to `<body>` at z 70, while `BaseModal` content sits at z 71 with outside pointer events disabled.
   - The plan view header must therefore not open a portalled popover. It uses the slot's inline presentation.

   → Task 6 ("inline mode toggles the status panel instead of opening a popover"), Task 9 ("opens the request form inline").
5. **A deck request whose deck has no theme or no slides, and a plan with no projection.** These must show the text-only card (title, version, slide count), never "This deck has no style to render with." A withdrawn request offers no record download. → Task 12 (`requestHeroKind`, `canDownloadRecord`), Task 15 ("renders a theme-less deck request as the text card and decides it").

---

## File Structure

All paths relative to WT.

| File | Status | Responsibility |
|---|---|---|
| `docs/tracks/client-lane-deck-plan-requests.track.md` | create | Track file: baselines, checklist, session log |
| `src/services/client-lane.ts` | modify | Request fetchers/keys/hooks keyed by `(subjectType, subjectId)`; widened wire types; `ApprovalSubject`; `downloadApprovalRecord`; version labels for every type |
| `src/services/client-lane.test.ts` | modify | Endpoint params and keys per subject |
| `src/lib/client-lane/types.ts` | modify | `PublicRequestApproval.phase` nullable |
| `src/lib/client-lane/canvasApproval.ts`, `pendingArtboards.ts` | modify | Skip keyless (deck/plan) approvals |
| `src/lib/client-lane/canvasApproval.test.ts` | create | Keyless guard tests |
| `src/lib/client-lane/subjectRequests.ts` (+ `.test.ts`) | create | Agency pure rules (copy, slot state, reasons, selection, item lines, meta, open request, filenames) |
| `src/lib/client-lane/requests.ts` | modify | `buildRequestPayload` phases optional; `requestOf` for 3 types |
| `src/lib/client-lane/requestFixtures.ts` | modify | Deck fixtures |
| `src/lib/client-lane/drain.ts` (+ `.test.ts`) | create | `pendingRoundOf` |
| `src/lib/client-lane/planDecisions.ts` (+ `.test.ts`) | create | Plan "Decisions" rows from requests + drained rounds |
| `src/lib/client-lane/requestDecision.ts` (+ `.test.ts`) | create | Client-page pure rules |
| `src/lib/client-lane/recordPdf.ts` | create | `saveBlob` (browser download) |
| `src/lib/client-lane/round.ts`, `round.test.ts` | modify | Title/OG for deck/plan request links |
| `src/lib/client-lane/testFixtures.ts` | modify | `deckRequestLink`, `planRequestLink` |
| `src/lib/client-lane/publicApi.ts` | modify | `downloadPublicRecord` |
| `src/lib/analytics/client-lane-events.ts` | modify | `subject_type` on request events; surfaces; record events |
| `src/components/client-lane/agency/useRequestActions.tsx` (+ `.test.tsx`) | modify | Subject-aware verbs + "Download record" |
| `src/components/client-lane/agency/RequestForm.tsx` (+ `.test.tsx`) | create | Generic request form (shared fields + send step) |
| `src/components/client-lane/agency/KvRequestItems.tsx` | create | KV phase pills + folds (moved out of `KvRequestForm`) |
| `src/components/client-lane/agency/SubjectRequestItem.tsx`, `ItemThumb.tsx` | create | Deck/plan item row; thumbnail per subject |
| `src/components/client-lane/agency/KvRequestForm.tsx` | delete | Replaced by `RequestForm` |
| `src/components/client-lane/agency/ApprovalRequestsSection.tsx` (+ `.test.tsx`) | rename from `KvApprovalRequestsSection.tsx` | Generic Share-dialog section |
| `src/components/client-lane/agency/ApprovalStatusList.tsx` (+ `.test.tsx`) | rename from `KvApprovalStatusList.tsx` | Generic status popover body |
| `src/components/client-lane/agency/ClientApprovalSlot.tsx` (+ `.test.tsx`) | rename from `KvClientApprovalSlot.tsx` | Generic top-bar slot, popover or inline |
| `src/components/client-lane/agency/RequestLinkRow.test.tsx` | modify | Import path |
| `src/components/client-lane/agency/KvArtboardThumb.tsx` | modify | `phase` nullable |
| `src/components/client-lane/agency/RequestApprovalPanel.tsx` | modify | `ApprovalSendStep` `versionLabel` override |
| `src/components/client-lane/agency/PlanDecisionsBlock.tsx` | modify | Reads requests + rounds; `enabled` prop |
| `src/components/client-lane/agency/useArtboardThumbnailSync.ts` (+ test) | modify | Keyed calls; nullable fingerprint |
| `src/components/client-lane/agency/KvReadyForClientTray.tsx` | modify | Analytics `subject_type` |
| `src/components/studio/kv-generator/KvSharePanel.tsx`, `KvGeneratorLayout.tsx`, `motion/KvMotionEditor.tsx` | modify | Import/prop swaps only |
| `src/hooks/useKvReadyToShare.ts`, `src/hooks/comments/useKvClientVisibility.ts` | modify | Keyed calls |
| `src/app/(canvas)/decks/[deckId]/components/DeckTopBar.tsx` | modify | Slot left of the right-cluster pill |
| `src/app/(canvas)/decks/[deckId]/components/DeckShareLinks.tsx` | modify | Approval-requests section, drain card, tokens |
| `src/components/brands/campaign-planner/PlanViewModal.tsx` (+ `.test.tsx`) | create | Plan view modal with header bar (title, slot inline, Share), inline form/status, decisions |
| `src/components/brands/campaign-planner/SavedPlansList.tsx` | modify | Uses `PlanViewModal` |
| `src/components/brands/campaign-planner/SharePlanDialog.tsx` | modify | Section swap + drain block |
| `src/components/brands/campaigns-lifecycle/CampaignsLifecycleView.tsx` | modify | `PlanViewModal`, menu rewiring, flag gate |
| `src/lib/campaigns-lifecycle/approvalMenu.ts` (+ `.test.ts`) | create | Lifecycle approval menu keys |
| `src/lib/campaign-planner/hooks.ts` | modify | `useSetPlanApproval` re-reads the plan's requests |
| `src/components/client-lane/RequestRail.tsx` (+ `.test.tsx`) | modify | `RequestEntry`; label props; pin hint |
| `src/components/client-lane/sheets/NewVersionNoteSheet.tsx` | modify | Retitled to "Request changes" |
| `src/components/client-lane/kv/requestItems.ts`, `kv/KvRequestHero.tsx` | modify | `RequestEntry` supertype; intent type from lib |
| `src/components/client-lane/RequestHero.tsx`, `SubjectTextCard.tsx` | create | Hero dispatcher; text-only card |
| `src/components/client-lane/DecisionPage.tsx` | modify | Entries for deck/plan, sheets gating, record button, labels |
| `src/components/client-lane/DecisionPage.request.test.tsx` | create | Deck request link end to end (text card path) |
| `src/app/s/[token]/page.tsx` | modify | Description from any request |
| `src/lib/client-lane/tokenHygiene.test.ts` | create | Banned-class scan over the light-mode surfaces |

---

## Phase 4 — generic components, KV unchanged

### Task 0: Pre-flight — worktree, baselines, track file

**Files:**
- Create: `docs/tracks/client-lane-deck-plan-requests.track.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the worktree WT; `TSC_BASELINE` (whole-project `error TS` count), per-file tsc counts and the per-file baseline test results, all written in the track. Every later gate compares against these.

- [ ] **Step 1: Create the worktree from the latest develop**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && /usr/bin/git fetch origin && /usr/bin/git worktree add -b feature/daffa/vc-client-lane-deck-plan-requests .worktrees/client-lane-deck-plan-requests origin/develop
```

Expected: `Preparing worktree (new branch 'feature/daffa/vc-client-lane-deck-plan-requests')`. If the branch already exists, STOP and ask Daffa; never reset or delete it.

- [ ] **Step 2: Install and copy the env (memory: a worktree has no `node_modules` and no `.env.local`)**

```bash
cd WT && bun install && cp ../../.env.local .env.local && /usr/bin/git status --short
```

Expected: install finishes; `git status --short` prints nothing (both are gitignored). If `.env.local` is missing in `web/`, note it in the track: tests do not need it, but `bun dev` would silently never call the api.

- [ ] **Step 3: Record the tsc baseline**

```bash
cd WT && npx tsc --noEmit -p . > /tmp/tsc-base.txt 2>&1; /usr/bin/grep -c "error TS" /tmp/tsc-base.txt; /usr/bin/grep -oE "^src/[^(]+" /tmp/tsc-base.txt | /usr/bin/grep -E "client-lane|KvGeneratorLayout|KvMotionEditor|KvSharePanel|DeckTopBar|DeckShareLinks|campaign-planner|campaigns-lifecycle|useKvReadyToShare|useKvClientVisibility" | sort | uniq -c
```

Expected: one number (≈895 per the last track; the real number is whatever prints) plus per-file counts (expect `KvGeneratorLayout.tsx` 1, `KvMotionEditor.tsx` 1). Write both into the track (Step 5).

- [ ] **Step 4: Run the baseline suites, one file per invocation**

```bash
cd WT && F=(src/lib/client-lane/round.test.ts src/lib/client-lane/pins.test.ts src/lib/client-lane/versionLabels.test.ts src/lib/client-lane/commentThreads.test.ts src/services/client-lane.test.ts src/components/client-lane/DecisionPage.test.tsx src/components/client-lane/PinLayer.test.tsx src/components/client-lane/PinNotePopover.test.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/components/client-lane/agency/RequestLinkRow.test.tsx src/components/client-lane/agency/useArtboardThumbnailSync.test.ts src/components/client-lane/kv/KvLinkGallery.test.tsx src/components/client-lane/kv/swipe.test.ts src/components/client-lane/kv/KvRequestHero.test.tsx src/components/client-lane/kv/roundItems.test.ts src/components/client-lane/kv/KvRoundHero.test.tsx src/components/client-lane/kv/KvShareBoardCanvas.test.tsx src/components/studio/kv-generator/KvSharePanel.test.tsx src/components/brands/campaign-planner/SharePlanDialog.test.tsx src/components/brands/campaign-planner/SavedPlansList.test.tsx src/lib/campaigns-lifecycle/rowModel.test.ts); for f in "${F[@]}"; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: pass/fail counts per file. Known before you start, from the 2026-10-01 track: `KvSharePanel.test.tsx` "Request approval toggle" tests are stale since Part A (fast mode) and fail. `SavedPlansList.test.tsx` uses `screen` and may fail under bun. Record EVERY `(fail)` line name verbatim in the track. Later tasks compare their run of the same file against this list. A failure not on the list is a regression.

- [ ] **Step 5: Write the track file**

Create `docs/tracks/client-lane-deck-plan-requests.track.md`:

```markdown
---
prd: client-lane-deck-plan-requests
parent_prd: docs/superpowers/specs/2026-10-06-client-lane-deck-plan-approval-requests-design.md
service: web
branch: feature/daffa/vc-client-lane-deck-plan-requests
worktree: web/.worktrees/client-lane-deck-plan-requests
base: origin/develop @ <short sha printed by `git rev-parse --short HEAD`>
flag: show-client-lane (agency side only; /s/* unflagged)
pr_url: null
status: in_progress
---

# Track — Client Lane: deck and plan on approval requests (web)

Plan: `docs/superpowers/plans/2026-10-06-client-lane-deck-plan-requests-web.md` (workspace root). Spec 1 of the "align deck and plan approval with KV" ticket. The api half lives on the api branch of the same name and merges first.

## Status

| Item | Status |
|------|--------|
| Spec | approved (Spec 1) |
| Service PRD | n/a — spec + plan |
| Implementation | in_progress |
| PR | not_submitted |

## Baselines (Task 0)

- `tsc` errors, whole project: <N>
- `tsc` errors per touched file: <paste the uniq -c lines>
- Pre-existing test failures (one file per run): <file → failing test names, or "none">

## Task Checklist

- [x] Task 0: worktree, baselines, track
- [ ] Task 1: service layer keyed by subject
- [ ] Task 2: agency pure rules
- [ ] Task 3: analytics subject_type + useRequestActions
- [ ] Task 4: RequestForm split
- [ ] Task 5: ApprovalRequestsSection + ApprovalStatusList
- [ ] Task 6: ClientApprovalSlot + KV mounts
- [ ] Task 7: deck top bar + Share dialog + drain
- [ ] Task 8: PlanDecisionsBlock reads requests
- [ ] Task 9: PlanViewModal (plan header)
- [ ] Task 10: SharePlanDialog section swap
- [ ] Task 11: lifecycle row menu
- [ ] Task 12: requestOf + client-page rules
- [ ] Task 13: title and OG for deck/plan request links
- [ ] Task 14: rail + action bar + note sheet
- [ ] Task 15: RequestHero + DecisionPage wiring
- [ ] Task 16: light-mode token pass
- [ ] Task 17: gates, manual two-device pass, Lark rows

## Session Log

### 2026-10-06 — daffa (plan executor)
- Task 0: worktree created, baselines recorded above.
```

Fill the `<…>` from Steps 1–4. Nothing may stay in angle brackets.

- [ ] **Step 6: Commit**

```bash
cd WT && /usr/bin/git add docs/tracks/client-lane-deck-plan-requests.track.md && /usr/bin/git commit -F - <<'EOF'
docs(web): open track for client lane deck and plan requests

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 1: Service layer keyed by subject

**Files:**
- Modify: `src/services/client-lane.ts` (the "KV approval requests" block from `AgencyRequestApproval` to `useResendApprovalRequest`, and `useApprovalVersionLabels`)
- Modify: `src/lib/client-lane/types.ts` (`PublicRequestApproval.phase`)
- Modify: `src/lib/client-lane/canvasApproval.ts:89-111` (`artboardVerdicts`), `src/lib/client-lane/pendingArtboards.ts:44-50`
- Modify: `src/components/client-lane/kv/requestItems.ts` (`requestArtboards` loop)
- Modify: `src/components/client-lane/agency/KvArtboardThumb.tsx`, `KvClientApprovalSlot.tsx`, `KvRequestForm.tsx`, `KvApprovalRequestsSection.tsx`, `KvApprovalStatusList.tsx`, `useRequestActions.tsx`, `useArtboardThumbnailSync.ts`, `useArtboardThumbnailSync.test.ts`
- Modify: `src/hooks/useKvReadyToShare.ts`, `src/hooks/comments/useKvClientVisibility.ts`, `src/components/studio/kv-generator/KvSharePanel.tsx`, `KvGeneratorLayout.tsx` (~5201, ~8608), `motion/KvMotionEditor.tsx` (~1689, ~1697)
- Modify: `src/lib/analytics/client-lane-events.ts` (`trackStatusRowJumped.phase` nullable)
- Test: `src/services/client-lane.test.ts` (modify), `src/lib/client-lane/canvasApproval.test.ts` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces (every later task uses these exact names):
  - `interface ApprovalSubject { type: ShareSubjectType; id: string; name: string }`;
  - `approvalRequestsRoot(subjectType, subjectId)`, `approvalRequestsKey(subjectType, subjectId)`, `approvalRequestPreviewKey(subjectType, subjectId)`;
  - `previewApprovalRequest(subjectType, subjectId)`, `listApprovalRequests(subjectType, subjectId)`;
  - `createApprovalRequest(subjectType, subjectId, input)`, `downloadApprovalRecord(requestId): Promise<Blob>`;
  - `useApprovalRequestPreview(subjectType, subjectId, opts?)`, `useApprovalRequests(subjectType, subjectId, opts?)`;
  - `useCreateApprovalRequest(subjectType, subjectId)`, `useWithdrawApprovalRequest(subjectType, subjectId)`;
  - the widened types in "API contract assumed".

  `subjectId` is `string | null | undefined` for the two queries (disabled when falsy) and `string` for the two mutations.

- [ ] **Step 1: Write the failing tests**

Replace the import line of `src/services/client-lane.test.ts` and append the new `describe`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

import axiosInstance from "@/services/axios";

import {
  approvalApiError,
  approvalRequestPreviewKey,
  approvalRequestsKey,
  approvalRequestsRoot,
  createApprovalRequest,
  downloadApprovalRecord,
  listApprovalRequests,
  previewApprovalRequest,
} from "./client-lane";
```

```ts
describe("approval requests keyed by subject (spec 2026-10-06 §5.1)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("lists a deck's requests under its own subject type", async () => {
    const get = vi
      .spyOn(axiosInstance, "get")
      .mockResolvedValue({ data: { data: [] } } as never);
    await listApprovalRequests("deck", "d1");
    expect(get).toHaveBeenCalledWith("v1/approval-requests", {
      params: { subject_type: "deck", subject_id: "d1" },
    });
  });

  it("previews a plan request under its own subject type", async () => {
    const get = vi
      .spyOn(axiosInstance, "get")
      .mockResolvedValue({ data: { data: { total: 1 } } } as never);
    await previewApprovalRequest("campaign", "p1");
    expect(get).toHaveBeenCalledWith("v1/approval-requests/preview", {
      params: { subject_type: "campaign", subject_id: "p1" },
    });
  });

  it("creates a plan request with no kv_phases", async () => {
    const post = vi
      .spyOn(axiosInstance, "post")
      .mockResolvedValue({ data: { data: {} } } as never);
    await createApprovalRequest("campaign", "p1", { approver_emails: [] });
    expect(post).toHaveBeenCalledWith("v1/approval-requests", {
      subject_type: "campaign",
      subject_id: "p1",
      approver_emails: [],
    });
  });

  it("keys every request query by subject type and id", () => {
    expect(approvalRequestsRoot("deck", "d1")).toEqual([
      "approval-requests",
      "deck",
      "d1",
    ]);
    expect(approvalRequestsKey("kv_file", "f1")).toEqual([
      "approval-requests",
      "kv_file",
      "f1",
      "list",
    ]);
    expect(approvalRequestPreviewKey("campaign", "p1")).toEqual([
      "approval-requests",
      "campaign",
      "p1",
      "preview",
    ]);
  });

  it("fetches a request's approval record as a blob", async () => {
    const pdf = new Blob(["%PDF-1.7"], { type: "application/pdf" });
    const get = vi
      .spyOn(axiosInstance, "get")
      .mockResolvedValue({ data: pdf } as never);
    await expect(downloadApprovalRecord("req1")).resolves.toBe(pdf);
    expect(get).toHaveBeenCalledWith("v1/approval-requests/req1/record.pdf", {
      responseType: "blob",
    });
  });
});
```

Create `src/lib/client-lane/canvasApproval.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { artboardVerdicts } from "./canvasApproval";
import { pendingArtboards } from "./pendingArtboards";
import { agencyRequest, requestApproval } from "./requestFixtures";

/** A deck / plan approval: one item, no artboard key (spec 2026-10-06 §4.2). */
const deckRequest = agencyRequest({
  approvals: [
    requestApproval({
      subject_key: null,
      phase: null,
      label: "Deck",
      version_id: "dv4",
    }),
  ],
});

describe("KV canvas rules ignore keyless (deck / plan) approvals", () => {
  it("gives a keyless approval no artboard verdict", () => {
    expect(artboardVerdicts([deckRequest]).size).toBe(0);
  });

  it("leaves a keyless approval out of the pending artboards", () => {
    const p = pendingArtboards([deckRequest]);
    expect([
      p.boardVersionIds.size,
      p.resizeRowIds.size,
      p.motionProjectIds.size,
    ]).toEqual([0, 0, 0]);
  });

  it("still keys a KV artboard by its subject key", () => {
    expect([...artboardVerdicts([agencyRequest()]).keys()]).toEqual([
      "board:g0",
    ]);
  });
});
```

- [ ] **Step 2: Run them to see them fail**

```bash
cd WT && bun test src/services/client-lane.test.ts
cd WT && bun test src/lib/client-lane/canvasApproval.test.ts
```

Expected:
- services: the four keyed tests FAIL. Today the fetchers take `fileId` and hard-code `subject_type: "kv_file"`, so params read `{ subject_type: "kv_file", subject_id: "deck" }`. `downloadApprovalRecord` is not exported (`TypeError: … is not a function`).
- canvasApproval: "gives a keyless approval no artboard verdict" FAILS (size 1, keyed `null`), and "leaves a keyless approval out…" FAILS with `TypeError: null is not an object (evaluating 'a.subject_key.split')`.

- [ ] **Step 3: Implement the service layer**

In `src/services/client-lane.ts`:

1. Widen `AgencyRequestApproval`, `ApprovalRequestPreviewItem`, `ApprovalRequestPreview` and `CreateApprovalRequestInput` to the exact shapes in "API contract assumed". Keep every doc comment that still holds, and add the `null`-for-deck/plan notes.
2. Replace the three key helpers, the `kvSubject` const and the three fetchers with:

```ts
/** The subject a request is about — what every generic approval component
 *  takes (spec 2026-10-06 §5.1). `name` is the title the send step quotes. */
export interface ApprovalSubject {
  type: ShareSubjectType;
  id: string;
  name: string;
}

/** Every request query on a subject shares this prefix, so one invalidation
 *  refreshes the list AND the preview. */
export const approvalRequestsRoot = (
  subjectType: ShareSubjectType,
  subjectId: string
) => ["approval-requests", subjectType, subjectId] as const;
export const approvalRequestsKey = (
  subjectType: ShareSubjectType,
  subjectId: string
) => [...approvalRequestsRoot(subjectType, subjectId), "list"] as const;
export const approvalRequestPreviewKey = (
  subjectType: ShareSubjectType,
  subjectId: string
) => [...approvalRequestsRoot(subjectType, subjectId), "preview"] as const;

const subjectParams = (subjectType: ShareSubjectType, subjectId: string) => ({
  subject_type: subjectType,
  subject_id: subjectId,
});

export async function previewApprovalRequest(
  subjectType: ShareSubjectType,
  subjectId: string
): Promise<ApprovalRequestPreview> {
  const res = await axiosInstance.get<{ data: ApprovalRequestPreview }>(
    "v1/approval-requests/preview",
    { params: subjectParams(subjectType, subjectId) }
  );
  return res.data.data;
}

/** Every request on the subject — open first, then newest first (api order). */
export async function listApprovalRequests(
  subjectType: ShareSubjectType,
  subjectId: string
): Promise<AgencyRequest[]> {
  const res = await axiosInstance.get<{ data: AgencyRequest[] }>(
    "v1/approval-requests",
    { params: subjectParams(subjectType, subjectId) }
  );
  return res.data.data;
}

export async function createApprovalRequest(
  subjectType: ShareSubjectType,
  subjectId: string,
  input: CreateApprovalRequestInput
): Promise<CreateApprovalRequestResponse> {
  const res = await axiosInstance.post<{ data: CreateApprovalRequestResponse }>(
    "v1/approval-requests",
    { ...subjectParams(subjectType, subjectId), ...input }
  );
  return res.data.data;
}

/** The request's audit-record PDF (spec 2026-10-06 §4.8) — any status. */
export async function downloadApprovalRecord(id: string): Promise<Blob> {
  const res = await axiosInstance.get<Blob>(
    `v1/approval-requests/${id}/record.pdf`,
    { responseType: "blob" }
  );
  return res.data;
}
```

`uploadArtboardThumbnail`, `withdrawApprovalRequest` and `resendApprovalRequest` are unchanged.

3. Replace the four request hooks:

```ts
export function useApprovalRequestPreview(
  subjectType: ShareSubjectType,
  subjectId: string | null | undefined,
  opts: { enabled?: boolean } = {}
) {
  return useQuery({
    queryKey: approvalRequestPreviewKey(subjectType, subjectId ?? ""),
    queryFn: () => previewApprovalRequest(subjectType, subjectId as string),
    enabled: Boolean(subjectId) && (opts.enabled ?? true),
    staleTime: 15_000,
  });
}

export function useApprovalRequests(
  subjectType: ShareSubjectType,
  subjectId: string | null | undefined,
  opts: { enabled?: boolean } = {}
) {
  return useQuery({
    queryKey: approvalRequestsKey(subjectType, subjectId ?? ""),
    queryFn: () => listApprovalRequests(subjectType, subjectId as string),
    enabled: Boolean(subjectId) && (opts.enabled ?? true),
    staleTime: 15_000,
  });
}

export function useCreateApprovalRequest(
  subjectType: ShareSubjectType,
  subjectId: string
) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: CreateApprovalRequestInput) =>
      createApprovalRequest(subjectType, subjectId, input),
    onSuccess: () => {
      void qc.invalidateQueries({
        queryKey: approvalRequestsRoot(subjectType, subjectId),
      });
    },
  });
}

export function useWithdrawApprovalRequest(
  subjectType: ShareSubjectType,
  subjectId: string
) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => withdrawApprovalRequest(id),
    onSuccess: () => {
      void qc.invalidateQueries({
        queryKey: approvalRequestsRoot(subjectType, subjectId),
      });
    },
  });
}
```

4. In `useApprovalVersionLabels`, deck and plan labels now include their requests (a deck request's `v4` labels its pins in the editor's comment panel):

```ts
  const approvals = useApprovals(subjectType, subjectId, {
    enabled: enabled && !isKv,
  });
  const requests = useApprovalRequests(subjectType, subjectId, { enabled });
```

Update the doc comment: "Decks and plans read their P0a rounds AND their requests. A KV file reads only its requests."

- [ ] **Step 4: Widen the public type and guard the KV-only rules**

`src/lib/client-lane/types.ts`, in `PublicRequestApproval`:

```ts
  /** The KV phase; null on a deck / plan request (spec 2026-10-06 §4.2). */
  phase: KvSharePhase | null;
```

`src/lib/client-lane/canvasApproval.ts`, the first lines of the inner loop of `artboardVerdicts`:

```ts
    for (const a of request.approvals) {
      // Deck / plan approvals have no artboard key — nothing to chip.
      if (a.subject_key === null || seen.has(a.subject_key)) continue;
      seen.add(a.subject_key);
```

`src/lib/client-lane/pendingArtboards.ts`, before the `split`:

```ts
      if (a.subject_key === null) continue;
      const [kind, id] = a.subject_key.split(":");
```

`src/components/client-lane/kv/requestItems.ts`, the top of the `requestArtboards` loop:

```ts
  for (const approval of view.approvals) {
    // KV only: a deck / plan approval (phase null) is never an artboard.
    if (approval.phase === null) continue;
    const phase = approval.phase;
    const item =
      approval.snapshot ?? findInDocument(document, approval.version_id);
```

Then use `phase` instead of `approval.phase` in `caption:` and `phase:` of the pushed entry.

`src/components/client-lane/agency/KvArtboardThumb.tsx`: the prop type becomes `phase: KvSharePhase | null;`. The existing `PHASE_ICON[phase as keyof typeof PHASE_ICON] ?? ImageSquare` already falls back for `null`.

`src/components/client-lane/agency/useArtboardThumbnailSync.ts`: `ThumbnailSource.fingerprint` becomes `string | null`. Change the two key calls to `approvalRequestPreviewKey("kv_file", fileId)` and `approvalRequestsKey("kv_file", fileId)`. `useArtboardThumbnailSync.test.ts`: both `approvalRequestPreviewKey(FILE)` become `approvalRequestPreviewKey("kv_file", FILE)`.

`src/lib/analytics/client-lane-events.ts`, `trackStatusRowJumped`: `phase: KvSharePhase | null;` with the comment "null on a deck / plan row".

- [ ] **Step 5: Swap every KV call site (no behaviour change)**

| File | Change |
|---|---|
| `src/hooks/useKvReadyToShare.ts` | `approvalRequestsRoot(fileId)` → `approvalRequestsRoot("kv_file", fileId)` |
| `src/hooks/comments/useKvClientVisibility.ts` | `useApprovalRequests(enabled ? fileId : null, { enabled })` → `useApprovalRequests("kv_file", enabled ? fileId : null, { enabled })` |
| `src/components/studio/kv-generator/KvSharePanel.tsx` | `approvalRequestsRoot(fileId)` → `approvalRequestsRoot("kv_file", fileId)` |
| `KvGeneratorLayout.tsx` ~5201 | `useApprovalRequests(clientApprovalOn ? liveFileId : null)` → `useApprovalRequests("kv_file", clientApprovalOn ? liveFileId : null)` |
| `KvGeneratorLayout.tsx` ~8616 | `onJump={(approval) => { if (approval.subject_key === null \|\| approval.phase === null) return; jumpToArtboard({ subjectKey: approval.subject_key, phase: approval.phase, versionId: approval.version_id }); }}` |
| `motion/KvMotionEditor.tsx` ~1689 | `useApprovalRequests(clientLane ? fileId : null)` → `useApprovalRequests("kv_file", clientLane ? fileId : null)` |
| `motion/KvMotionEditor.tsx` ~1696 | first line of `handleApprovalJump`: `if (approval.subject_key === null \|\| approval.phase === null) return;` |
| `agency/KvClientApprovalSlot.tsx` | `useApprovalRequestPreview(fileId)` → `useApprovalRequestPreview("kv_file", fileId)`; `useApprovalRequests(fileId)` → `useApprovalRequests("kv_file", fileId)` |
| `agency/KvApprovalRequestsSection.tsx` | the two hooks gain `"kv_file"` as first argument |
| `agency/KvRequestForm.tsx` | hooks + `approvalRequestsRoot` gain `"kv_file"`. Filters become `data.items.filter((item) => item.phase !== null && phases.includes(item.phase))`, `data.already_approved.filter((a) => a.phase === null \|\| !off.includes(a.phase))` and the same for `waiting`. The three list keys become `a.subject_key ?? a.version_id` / `w.subject_key ?? w.version_id` / `item.subject_key ?? item.version_id`. |
| `agency/useRequestActions.tsx` | `useWithdrawApprovalRequest("kv_file", fileId)`; `approvalRequestsRoot("kv_file", fileId)` |

The `\|` in the table is a literal `|` in code. Every one of these is a mechanical swap. Tasks 3–6 replace the `agency/Kv*` files.

- [ ] **Step 6: Run the tests and the regression suites**

```bash
cd WT && bun test src/services/client-lane.test.ts
cd WT && bun test src/lib/client-lane/canvasApproval.test.ts
cd WT && bun test src/components/client-lane/agency/useArtboardThumbnailSync.test.ts
cd WT && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: the first three are all green. `KvSharePanel.test.tsx` shows exactly the Task 0 baseline failure list and nothing more.

- [ ] **Step 7: Mutation checks**
  - In `listApprovalRequests`, hard-code `subjectParams("kv_file", subjectId)`. "lists a deck's requests under its own subject type" must FAIL. Restore.
  - In `artboardVerdicts`, delete `a.subject_key === null ||`. "gives a keyless approval no artboard verdict" must FAIL. Restore.

- [ ] **Step 8: Type + lint gate**

```bash
cd WT && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
cd WT && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "services/client-lane|lib/client-lane|client-lane/agency|client-lane/kv|useKvReadyToShare|useKvClientVisibility|KvSharePanel|KvGeneratorLayout|KvMotionEditor|client-lane-events"
```

Expected: the count is ≤ baseline, and the second command shows only the baseline lines (`KvGeneratorLayout` 1, `KvMotionEditor` 1). Every widened type is caught here: fix each new error with a `null` guard like the ones above, never with a cast. Then run `npx eslint` on the touched files and expect 0 errors.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "previews a plan request under its own subject type" — in `previewApprovalRequest`, use `subjectParams("kv_file", subjectId)`.
- "creates a plan request with no kv_phases" — in `createApprovalRequest`, post `{ ...subjectParams("kv_file", subjectId), ...input }`.
- "keys every request query by subject type and id" — make `approvalRequestsRoot` return `["approval-requests", "kv_file", subjectId]`.
- "fetches a request's approval record as a blob" — drop `{ responseType: "blob" }`.
- "leaves a keyless approval out of the pending artboards" — delete `if (a.subject_key === null) continue;` in `pendingArtboards`.
- "still keys a KV artboard by its subject key" — invert the new guard to `a.subject_key !== null`.

- [ ] **Step 9: Commit**

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
refactor(web): key approval-request services by subject type

Request fetchers, query keys and hooks take (subjectType, subjectId);
wire types allow deck/plan's keyless, phaseless items; KV call sites
swap arguments only.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 2: Agency pure rules — `subjectRequests.ts`

**Files:**
- Create: `src/lib/client-lane/subjectRequests.ts`
- Modify: `src/lib/client-lane/requests.ts` (`buildRequestPayload`)
- Modify: `src/lib/client-lane/requestFixtures.ts` (deck fixtures)
- Test: `src/lib/client-lane/subjectRequests.test.ts`

**Interfaces:**
- Consumes (Task 1): the widened `AgencyRequest`, `AgencyRequestApproval`, `ApprovalRequestPreview`, `ApprovalRequestPreviewItem`. From existing code: `slotStateOf`, `SlotState`, `artboardWho` (`canvasApproval.ts`) and `plural`, `requestTitle` (`requests.ts`).
- Produces:
  - `SUBJECT_NOUN: Record<ShareSubjectType, { one: string; label: string }>`;
  - `subjectRequestTitle(r, type): string`;
  - `requestBlockedReason(type, preview | undefined, hasReadyMarks: boolean): string | null`;
  - `type SubjectSlotState = SlotState | { kind: "request"; disabledReason: string | null }`;
  - `subjectSlotState(type, requests, preview | undefined): SubjectSlotState`;
  - `newReadyLabel(type, n): string`, `subjectItemLine(item): string | null`;
  - `interface RequestSelection { phases; items; approved; waiting }` and `requestSelection(preview, off): RequestSelection`;
  - `itemMeta(approval): string | null`, `openRequestOf(requests): AgencyRequest | null`;
  - `recordFilename(title, requestNumber): string`, `withdrawNote(type): string`;
  - `buildRequestPayload({ phases: KvSharePhase[] | null, … })` (omits `kv_phases` for null);
  - fixtures `deckPreviewItem(overrides?)`, `deckApproval(overrides?)`.

- [ ] **Step 1: Add the deck fixtures**

Append to `src/lib/client-lane/requestFixtures.ts`:

```ts
/** A deck's one preview item (spec 2026-10-06 §4.2): no key, no phase, v4. */
export function deckPreviewItem(
  overrides: Partial<ApprovalRequestPreviewItem> = {}
): ApprovalRequestPreviewItem {
  return previewItem({
    subject_key: null,
    phase: null,
    label: "Deck",
    version_id: "dv4",
    round: 4,
    thumbnail_url: null,
    fingerprint: null,
    ...overrides,
  });
}

/** A deck request's one approval: no key, no phase, round 4. */
export function deckApproval(
  overrides: Partial<AgencyRequestApproval> = {}
): AgencyRequestApproval {
  return requestApproval({
    id: "apr_d",
    subject_key: null,
    phase: null,
    label: "Deck",
    round: 4,
    version_id: "dv4",
    thumbnail_url: null,
    fingerprint: null,
    ...overrides,
  });
}
```

- [ ] **Step 2: Write the failing tests**

Create `src/lib/client-lane/subjectRequests.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import type { AgencyRequestApprover } from "@/services/client-lane";

import {
  agencyRequest,
  deckApproval,
  deckPreviewItem,
  previewItem,
  requestPreview,
} from "./requestFixtures";
import { buildRequestPayload } from "./requests";
import {
  itemMeta,
  newReadyLabel,
  openRequestOf,
  recordFilename,
  requestBlockedReason,
  requestSelection,
  subjectItemLine,
  subjectRequestTitle,
  subjectSlotState,
  withdrawNote,
} from "./subjectRequests";
import type { ApprovalDecision } from "./types";

const DINA: AgencyRequestApprover = {
  name: "Dina",
  email: "dina@brand.test",
  user_id: null,
  personal_url: null,
  decided: false,
};

const DECIDED: ApprovalDecision = {
  id: "d1",
  actor: "Dina",
  outcome: "approved",
  note: null,
  pins: [],
  decided_at: null,
  advisory: false,
  deferred_until: null,
};

describe("requestBlockedReason", () => {
  it("names the missing brand for a deck", () => {
    expect(
      requestBlockedReason(
        "deck",
        requestPreview([], { blocked_reason: "no_brand" }),
        true
      )
    ).toBe("Link this deck to a brand to request approval");
  });

  it("names the missing brand for a plan", () => {
    expect(
      requestBlockedReason(
        "campaign",
        requestPreview([], { blocked_reason: "no_brand" }),
        true
      )
    ).toBe("Link this plan to a brand to request approval");
  });

  it("says a deck version is already approved", () => {
    const preview = requestPreview([], {
      already_approved: [
        { subject_key: null, phase: null, label: "Deck", version_id: "dv3" },
      ],
    });
    expect(requestBlockedReason("deck", preview, true)).toBe(
      "This version is already approved"
    );
  });

  it("says a deck version is still waiting", () => {
    const preview = requestPreview([], {
      waiting: [
        {
          subject_key: null,
          phase: null,
          label: "Deck",
          version_id: "dv3",
          request_number: 2,
        },
      ],
    });
    expect(requestBlockedReason("deck", preview, true)).toBe(
      "This version is still waiting on a decision"
    );
  });

  it("is null while a deck has something to send, and before the preview loads", () => {
    expect(
      requestBlockedReason("deck", requestPreview([deckPreviewItem()]), true)
    ).toBeNull();
    expect(requestBlockedReason("deck", undefined, true)).toBeNull();
  });

  it("keeps the KV reasons word for word", () => {
    expect(requestBlockedReason("kv_file", requestPreview([]), false)).toBe(
      "Mark artboards ready on the canvas first"
    );
    expect(requestBlockedReason("kv_file", requestPreview([]), true)).toBe(
      "Everything marked is approved or waiting"
    );
    expect(
      requestBlockedReason("kv_file", requestPreview([previewItem()]), true)
    ).toBeNull();
  });
});

describe("subjectSlotState", () => {
  it("offers Request approval on a deck with nothing sent", () => {
    expect(
      subjectSlotState("deck", [], requestPreview([deckPreviewItem()]))
    ).toEqual({ kind: "request", disabledReason: null });
  });

  it("disables it with the reason on a brand-less deck", () => {
    expect(
      subjectSlotState(
        "deck",
        [],
        requestPreview([], { blocked_reason: "no_brand" })
      )
    ).toEqual({
      kind: "request",
      disabledReason: "Link this deck to a brand to request approval",
    });
  });

  it("shows the status chip once a deck request exists", () => {
    const request = agencyRequest({
      approvals: [deckApproval()],
      approvers: [DINA],
    });
    expect(
      subjectSlotState("deck", [request], requestPreview([]))
    ).toMatchObject({ kind: "status", text: "Waiting on Dina · 0/1" });
  });

  it("treats a deck whose only request was withdrawn as never sent", () => {
    const withdrawn = agencyRequest({
      status: "not_relevant",
      approvals: [deckApproval({ status: "not_relevant" })],
    });
    expect(
      subjectSlotState("deck", [withdrawn], requestPreview([deckPreviewItem()]))
    ).toEqual({ kind: "request", disabledReason: null });
  });

  it("keeps KV's ready and hidden states", () => {
    expect(
      subjectSlotState("kv_file", [], requestPreview([previewItem()]))
    ).toEqual({ kind: "ready", readyTotal: 1 });
    expect(subjectSlotState("kv_file", [], requestPreview([]))).toEqual({
      kind: "hidden",
    });
  });
});

describe("copy per subject", () => {
  it("titles a deck request by its version, a KV one by artboards", () => {
    expect(
      subjectRequestTitle(
        agencyRequest({ number: 2, approvals: [deckApproval()] }),
        "deck"
      )
    ).toBe("Request 2 · v4");
    expect(subjectRequestTitle(agencyRequest(), "kv_file")).toBe(
      "Request 1 · 1 artboard"
    );
    expect(
      subjectRequestTitle(agencyRequest({ number: 2, approvals: [] }), "campaign")
    ).toBe("Request 2");
  });

  it("labels the extra Request button per subject", () => {
    expect(newReadyLabel("kv_file", 2)).toBe(
      "Request approval — 2 new artboards ready"
    );
    expect(newReadyLabel("deck", 1)).toBe(
      "Request approval — a new version is ready"
    );
  });

  it("says what a withdraw does per subject", () => {
    expect(withdrawNote("kv_file")).toBe(
      "Nobody can decide on its artboards after this. Their decisions so far stay on record."
    );
    expect(withdrawNote("deck")).toBe(
      "Nobody can decide on this deck after this. Decisions so far stay on record."
    );
    expect(withdrawNote("campaign")).toBe(
      "Nobody can decide on this plan after this. Decisions so far stay on record."
    );
  });
});

describe("subjectItemLine", () => {
  it("names the new version and the waiting one it replaces", () => {
    expect(
      subjectItemLine(
        deckPreviewItem({ replaces: { request_number: null, round: 3 } })
      )
    ).toBe("v4 · replaces v3, still waiting");
  });

  it("is the version alone when nothing waits", () => {
    expect(subjectItemLine(deckPreviewItem())).toBe("v4");
  });

  it("is null when the api sent no round and nothing is replaced", () => {
    expect(subjectItemLine(deckPreviewItem({ round: undefined }))).toBeNull();
  });
});

describe("requestSelection", () => {
  it("drops a KV phase that is turned off, with its listed rows", () => {
    const preview = requestPreview(
      [
        previewItem(),
        previewItem({ subject_key: "resize:r1", phase: "resize", version_id: "r1" }),
      ],
      {
        already_approved: [
          {
            subject_key: "resize:r2",
            phase: "resize",
            label: "IG Feed",
            version_id: "r2",
          },
        ],
      }
    );
    const s = requestSelection(preview, ["resize"]);
    expect(s.phases).toEqual(["craft"]);
    expect(s.items.map((i) => i.version_id)).toEqual(["g1"]);
    expect(s.approved).toEqual([]);
  });

  it("always keeps a deck's phaseless item", () => {
    const s = requestSelection(requestPreview([deckPreviewItem()]), ["craft"]);
    expect(s.items.map((i) => i.version_id)).toEqual(["dv4"]);
  });
});

describe("itemMeta", () => {
  it("shows pins without a decision as feedback", () => {
    expect(itemMeta(deckApproval({ pin_count: 2 }))).toBe(
      "Feedback, no decision yet · 2 pins"
    );
  });

  it("names who decided, then the pins", () => {
    expect(
      itemMeta(
        deckApproval({ status: "approved", pin_count: 1, decisions: [DECIDED] })
      )
    ).toBe("Dina · 1 pin");
  });

  it("does not call a replaced item feedback", () => {
    expect(
      itemMeta(deckApproval({ superseded_by_request_number: 3, pin_count: 2 }))
    ).toBe("2 pins");
  });

  it("is null with nothing to say", () => {
    expect(itemMeta(deckApproval())).toBeNull();
  });
});

describe("openRequestOf", () => {
  const closed = agencyRequest({
    id: "r1",
    number: 1,
    status: "approved",
    share_url: "https://app.test/s/a",
  });
  const open = agencyRequest({
    id: "r2",
    number: 2,
    share_url: "https://app.test/s/b",
  });

  it("is the open request with a live link", () => {
    expect(openRequestOf([closed, open])?.share_url).toBe("https://app.test/s/b");
  });

  it("is null when no request is open or its link is gone", () => {
    expect(openRequestOf([closed])).toBeNull();
    expect(
      openRequestOf([agencyRequest({ share_link_active: false })])
    ).toBeNull();
  });
});

describe("recordFilename", () => {
  it("makes the subject title safe for a file name", () => {
    expect(recordFilename("Ramadan 2027: strategy / v2", 3)).toBe(
      "Ramadan 2027- strategy - v2 — Request 3 — approval record.pdf"
    );
  });

  it("falls back when the title is blank", () => {
    expect(recordFilename("   ", 1)).toBe(
      "Approval — Request 1 — approval record.pdf"
    );
  });
});

describe("buildRequestPayload", () => {
  it("omits kv_phases for a deck or plan", () => {
    expect(
      buildRequestPayload({
        phases: null,
        emails: ["dina@brand.test"],
        message: "  ",
        decideBy: "",
      })
    ).toEqual({ approver_emails: ["dina@brand.test"] });
  });

  it("keeps kv_phases for KV", () => {
    expect(
      buildRequestPayload({
        phases: ["craft"],
        emails: [],
        message: "Hero is new",
        decideBy: "2026-10-09",
      })
    ).toEqual({
      kv_phases: ["craft"],
      approver_emails: [],
      message: "Hero is new",
      decide_by: "2026-10-09",
    });
  });
});
```

- [ ] **Step 3: Run it to see it fail**

```bash
cd WT && bun test src/lib/client-lane/subjectRequests.test.ts
```

Expected: the file errors at import (`Cannot find module './subjectRequests'`). bun shows `1 error`.

- [ ] **Step 4: Implement**

Create `src/lib/client-lane/subjectRequests.ts`:

```ts
/**
 * The agency side of approval requests for every subject (spec 2026-10-06
 * §5): the copy that differs per type, what the top-bar slot shows, why a
 * Request button is disabled, what one deck / plan item says. Pure — no
 * React, no api; type-only imports from the service.
 *
 * KV keeps every word it had: its branches call the KV helpers unchanged.
 */
import type {
  AgencyRequest,
  AgencyRequestApproval,
  ApprovalRequestPreview,
  ApprovalRequestPreviewItem,
} from "@/services/client-lane";
import type { KvSharePhase } from "@/types/kv/share-link";

import { artboardWho, slotStateOf, type SlotState } from "./canvasApproval";
import { plural, requestTitle } from "./requests";
import type { ShareSubjectType } from "./types";

export const SUBJECT_NOUN: Record<
  ShareSubjectType,
  { one: string; label: string }
> = {
  kv_file: { one: "artboard", label: "Key visual" },
  deck: { one: "deck", label: "Deck" },
  campaign: { one: "plan", label: "Campaign plan" },
};

/** "Request 2 · 3 artboards" (KV) / "Request 2 · v4" (deck, plan). */
export function subjectRequestTitle(
  r: Pick<AgencyRequest, "number" | "approvals">,
  type: ShareSubjectType
): string {
  if (type === "kv_file") return requestTitle(r);
  const round = r.approvals[0]?.round;
  return round ? `Request ${r.number} · v${round}` : `Request ${r.number}`;
}

/**
 * Why Request approval cannot be pressed, in words (spec §4.3, §5.2) —
 * null while it can, and while the preview is still loading.
 */
export function requestBlockedReason(
  type: ShareSubjectType,
  preview: ApprovalRequestPreview | undefined,
  hasReadyMarks: boolean
): string | null {
  if (!preview) return null;
  if (preview.blocked_reason === "no_brand") {
    return `Link this ${SUBJECT_NOUN[type].one} to a brand to request approval`;
  }
  if (type === "kv_file") {
    if (!hasReadyMarks) return "Mark artboards ready on the canvas first";
    return preview.total === 0
      ? "Everything marked is approved or waiting"
      : null;
  }
  if (preview.total > 0) return null;
  if (preview.waiting.length > 0) {
    return "This version is still waiting on a decision";
  }
  if (preview.already_approved.length > 0) {
    return "This version is already approved";
  }
  return "Nothing new to send";
}

export type SubjectSlotState =
  | SlotState
  | { kind: "request"; disabledReason: string | null };

/**
 * The top-bar slot (spec §5.2): KV keeps Part B's ready / hidden / status.
 * A deck or plan with no live request shows Request approval — always,
 * disabled with its reason when it cannot be sent.
 */
export function subjectSlotState(
  type: ShareSubjectType,
  requests: AgencyRequest[],
  preview: ApprovalRequestPreview | undefined
): SubjectSlotState {
  const base = slotStateOf(requests, preview?.total ?? 0);
  if (type === "kv_file" || base.kind === "status") return base;
  return {
    kind: "request",
    disabledReason: requestBlockedReason(type, preview, true),
  };
}

/** The small Request button beside a status chip. */
export function newReadyLabel(type: ShareSubjectType, n: number): string {
  return type === "kv_file"
    ? `Request approval — ${plural(n, "new artboard")} ready`
    : "Request approval — a new version is ready";
}

/** "v4 · replaces v3, still waiting" (spec §5.1) — a deck / plan item. */
export function subjectItemLine(
  item: Pick<ApprovalRequestPreviewItem, "round" | "replaces">
): string | null {
  const parts = [
    item.round ? `v${item.round}` : null,
    item.replaces ? `replaces v${item.replaces.round}, still waiting` : null,
  ].filter((p): p is string => p !== null);
  return parts.length > 0 ? parts.join(" · ") : null;
}

export interface RequestSelection {
  phases: KvSharePhase[];
  items: ApprovalRequestPreviewItem[];
  approved: ApprovalRequestPreview["already_approved"];
  waiting: ApprovalRequestPreview["waiting"];
}

/**
 * What the form would send with some KV phases turned off. A phaseless
 * (deck / plan) row is never filtered.
 */
export function requestSelection(
  preview: ApprovalRequestPreview,
  off: readonly KvSharePhase[]
): RequestSelection {
  const phases = preview.phases
    .map((p) => p.phase)
    .filter((p) => !off.includes(p));
  const keep = (phase: KvSharePhase | null) =>
    phase === null || !off.includes(phase);
  return {
    phases,
    items: preview.items.filter(
      (i) => i.phase === null || phases.includes(i.phase)
    ),
    approved: preview.already_approved.filter((a) => keep(a.phase)),
    waiting: preview.waiting.filter((w) => keep(w.phase)),
  };
}

/**
 * A status row's second line: pins without a decision read "Feedback, no
 * decision yet" (spec §6.3, all types); otherwise who decided and the pins.
 */
export function itemMeta(
  a: Pick<
    AgencyRequestApproval,
    "status" | "superseded_by_request_number" | "pin_count" | "decisions"
  >
): string | null {
  const pins = a.pin_count > 0 ? plural(a.pin_count, "pin") : null;
  if (
    a.status === "pending" &&
    a.superseded_by_request_number === null &&
    pins
  ) {
    return `Feedback, no decision yet · ${pins}`;
  }
  const parts = [artboardWho(a), pins].filter(Boolean);
  return parts.length > 0 ? parts.join(" · ") : null;
}

/** The newest open request whose link still works — the "approval link". */
export function openRequestOf(requests: AgencyRequest[]): AgencyRequest | null {
  return (
    [...requests]
      .filter(
        (r) => r.status === "pending" && r.share_link_active && r.share_url
      )
      .sort((a, b) => b.number - a.number)[0] ?? null
  );
}

/** "Ramadan 2027 strategy — Request 2 — approval record.pdf". */
export function recordFilename(title: string, requestNumber: number): string {
  const base =
    title
      .replace(/[\\/:*?"<>|]+/g, "-")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 80) || "Approval";
  return `${base} — Request ${requestNumber} — approval record.pdf`;
}

/** The withdraw confirm's line. */
export function withdrawNote(type: ShareSubjectType): string {
  return type === "kv_file"
    ? "Nobody can decide on its artboards after this. Their decisions so far stay on record."
    : `Nobody can decide on this ${SUBJECT_NOUN[type].one} after this. Decisions so far stay on record.`;
}
```

In `src/lib/client-lane/requests.ts`, replace `buildRequestPayload`:

```ts
/** `POST v1/approval-requests` body — optional fields omitted, not empty;
 *  `kv_phases` only for KV (`phases: null` for a deck or plan). */
export function buildRequestPayload(input: {
  phases: KvSharePhase[] | null;
  emails: string[];
  message: string;
  decideBy: string;
}): CreateApprovalRequestInput {
  const message = input.message.trim();
  return {
    ...(input.phases ? { kv_phases: [...input.phases] } : {}),
    approver_emails: [...input.emails],
    ...(message ? { message } : {}),
    ...(input.decideBy ? { decide_by: input.decideBy } : {}),
  };
}
```

- [ ] **Step 5: Run it to see it pass**

```bash
cd WT && bun test src/lib/client-lane/subjectRequests.test.ts
```

Expected: all pass, `0 fail`, no `error` line.

- [ ] **Step 6: Mutation checks**
  - In `subjectSlotState`, return `base` for every type. "offers Request approval on a deck with nothing sent" must FAIL. Restore.
  - In `itemMeta`, drop the `a.status === "pending" &&` clause. "names who decided, then the pins" must FAIL. Restore.
  - In `requestSelection`, drop `i.phase === null ||`. "always keeps a deck's phaseless item" must FAIL. Restore.
  - In `buildRequestPayload`, always spread `kv_phases: [...(input.phases ?? [])]`. "omits kv_phases for a deck or plan" must FAIL. Restore.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "names the missing brand for a deck" — delete the `no_brand` branch.
- "names the missing brand for a plan" — hard-code `deck` in the no-brand sentence.
- "says a deck version is already approved" — delete the `already_approved` branch.
- "says a deck version is still waiting" — delete the `waiting` branch.
- "is null while a deck has something to send, and before the preview loads" — delete `if (preview.total > 0) return null;`.
- "keeps the KV reasons word for word" — change either KV sentence by one word.
- "disables it with the reason on a brand-less deck" — return `disabledReason: null` always.
- "shows the status chip once a deck request exists" — return the `request` kind before checking `base.kind`.
- "treats a deck whose only request was withdrawn as never sent" — in `slotStateOf`, drop the `not_relevant` filter.
- "keeps KV's ready and hidden states" — drop `type === "kv_file" ||`.
- "titles a deck request by its version, a KV one by artboards" — return `requestTitle(r)` for every type.
- "labels the extra Request button per subject" — return the KV sentence for every type.
- "says what a withdraw does per subject" — return the KV sentence for every type.
- "names the new version and the waiting one it replaces" — drop the `replaces` part.
- "is the version alone when nothing waits" — drop the `round` part.
- "is null when the api sent no round and nothing is replaced" — return `parts.join(" · ")` without the length check.
- "drops a KV phase that is turned off, with its listed rows" — ignore `off` in `keep`.
- "shows pins without a decision as feedback" — delete the feedback branch.
- "does not call a replaced item feedback" — drop the `superseded_by_request_number === null` clause.
- "is null with nothing to say" — return `parts.join(" · ")` without the length check.
- "is the open request with a live link" — replace the body with `requests.find((r) => r.share_url) ?? null`.
- "is null when no request is open or its link is gone" — drop the `share_link_active` filter.
- "makes the subject title safe for a file name" — drop the `[\\/:*?"<>|]` replace.
- "falls back when the title is blank" — drop `|| "Approval"`.
- "keeps kv_phases for KV" — drop the `kv_phases` spread.

- [ ] **Step 7: Type + lint gate** (as Task 1 Step 8, paths `lib/client-lane`), then commit:

```bash
cd WT && /usr/bin/git add src/lib/client-lane && /usr/bin/git commit -F - <<'EOF'
feat(web): agency rules for deck and plan approval requests

Slot state, disabled reasons, item lines, request titles and record
filenames per subject type; KV copy unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 3: Analytics `subject_type` + `useRequestActions` for any subject

**Files:**
- Create: `src/lib/client-lane/recordPdf.ts`
- Modify: `src/lib/analytics/client-lane-events.ts`
- Modify: `src/components/client-lane/agency/useRequestActions.tsx`
- Modify (callers): `agency/KvRequestForm.tsx`, `agency/KvApprovalRequestsSection.tsx`, `agency/KvClientApprovalSlot.tsx`, `agency/KvApprovalStatusList.tsx`, `agency/KvReadyForClientTray.tsx`, `src/components/client-lane/DecisionPage.tsx`
- Test: `src/components/client-lane/agency/useRequestActions.test.tsx` (create)

**Interfaces:**
- Consumes: Task 1 `downloadApprovalRecord`, `ApprovalSubject`, `useWithdrawApprovalRequest(subjectType, subjectId)`; Task 2 `recordFilename`, `withdrawNote`.
- Produces:
  - `useRequestActions(request: AgencyRequest, subject: ApprovalSubject)` → `{ verbs, copyLink, openLink, confirmingWithdraw, cancelWithdraw, doWithdraw, withdrawPending, downloadRecord }`;
  - `WithdrawConfirm` gains a required `note: string` prop;
  - `saveBlob(blob, filename)`;
  - analytics:
    - `subject_type: ShareSubjectType` on `trackApprovalRequestSent`, `…SendFailed`, `…FormOpened`, `…Withdrawn`, `…WithdrawFailed`, `…Resent`, `…ResendFailed`, `trackStatusChipOpened`, `trackStatusRowJumped`, `trackClientArtboardDecided`, `trackClientRequestDecisionFailed`, `trackClientRequestCompleted`;
    - `ApprovalSurface = "canvas" | "motion" | "deck" | "plan"`;
    - `ApprovalRequestFormSource` gains `"lifecycle_menu"`;
    - `trackApprovalRequestFormOpened.ready_total: number | null`;
    - new `trackApprovalRecordDownloaded({ subject_type, side })` and `trackApprovalRecordDownloadFailed({ subject_type, side, reason, http_status })` with `side: "agency" | "client"`.

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/agency/useRequestActions.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  agencyRequest,
  deckApproval,
} from "@/lib/client-lane/requestFixtures";
import axiosInstance from "@/services/axios";

import { useRequestActions } from "./useRequestActions";

const DECK = {
  type: "deck",
  id: "d1",
  name: "Ramadan 2027: strategy",
} as const;

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("useRequestActions — any subject (spec 2026-10-06 §5.1)", () => {
  it("reports the deck's subject type when its link is copied", async () => {
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText: vi.fn().mockResolvedValue(undefined) },
    });
    const request = agencyRequest({ approvals: [deckApproval()] });
    const { result } = renderHook(() => useRequestActions(request, DECK), {
      wrapper: Wrapper,
    });
    await act(async () => {
      await result.current.copyLink("menu");
    });
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_link_shared",
      expect.objectContaining({ subject_type: "deck", channel: "copy" })
    );
  });

  it("offers Download record on a closed request, and no Withdraw", () => {
    const request = agencyRequest({
      status: "approved",
      approvals: [deckApproval({ status: "approved" })],
    });
    const { result } = renderHook(() => useRequestActions(request, DECK), {
      wrapper: Wrapper,
    });
    const ids = result.current.verbs.map((v) => v.id);
    expect(ids).toContain("record");
    expect(ids).not.toContain("withdraw");
  });

  it("downloads the record under the subject's name", async () => {
    vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
    const get = vi
      .spyOn(axiosInstance, "get")
      .mockResolvedValue({ data: new Blob(["%PDF"]) } as never);
    Object.assign(URL, {
      createObjectURL: vi.fn(() => "blob:record"),
      revokeObjectURL: vi.fn(),
    });
    const names: string[] = [];
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(
      function (this: HTMLAnchorElement) {
        names.push(this.download);
      }
    );
    const request = agencyRequest({ number: 3, approvals: [deckApproval()] });
    const { result } = renderHook(() => useRequestActions(request, DECK), {
      wrapper: Wrapper,
    });
    await act(async () => {
      await result.current.downloadRecord();
    });
    expect(get).toHaveBeenCalledWith("v1/approval-requests/req1/record.pdf", {
      responseType: "blob",
    });
    expect(names).toEqual([
      "Ramadan 2027- strategy — Request 3 — approval record.pdf",
    ]);
  });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/components/client-lane/agency/useRequestActions.test.tsx
```

Expected:
- test 1 FAILS: `subject_type` is `"kv_file"`, hard-coded today.
- test 2 FAILS: there is no `record` verb.
- test 3 FAILS: `downloadRecord` is not a function.

- [ ] **Step 3: Change the analytics helpers**

In `src/lib/analytics/client-lane-events.ts`:

- Add `subject_type: ShareSubjectType;` as the FIRST property of the props of `trackApprovalRequestSent`, `trackApprovalRequestSendFailed`, `trackApprovalRequestFormOpened`, `trackApprovalRequestWithdrawn`, `trackApprovalRequestWithdrawFailed`, `trackApprovalRequestResent`, `trackApprovalRequestResendFailed`, `trackStatusChipOpened`, `trackStatusRowJumped`, `trackClientArtboardDecided`, `trackClientRequestDecisionFailed` and `trackClientRequestCompleted`. Doc each: "the subject the request is about (spec 2026-10-06 §5.4)".
- In `trackApprovalRequestSent`, add the doc to `artboard_count` and `phases`: "items for a deck / plan (always 1); `phases` is `[]` for a deck / plan".
- `export type ApprovalSurface = "canvas" | "motion" | "deck" | "plan";` with the doc "Which editor hosts the slot: the KV canvas, the Motion editor, the deck top bar, the plan view header."
- `export type ApprovalRequestFormSource = "share_dialog" | "tray" | "top_bar" | "lifecycle_menu";`
- In `trackApprovalRequestFormOpened`, `ready_total: number | null;` with the doc "null when the entry point has no preview (the lifecycle menu)".
- Append:

```ts
/** Which side downloaded an approval record (spec 2026-10-06 §4.8). */
export type ApprovalRecordSide = "agency" | "client";

/** The approval-record PDF reached the browser. */
export const trackApprovalRecordDownloaded = (props: {
  subject_type: ShareSubjectType;
  side: ApprovalRecordSide;
}) => safeCapture("client_lane.approval_record_downloaded", props);

export const trackApprovalRecordDownloadFailed = (props: {
  subject_type: ShareSubjectType;
  side: ApprovalRecordSide;
  reason: string;
  http_status: number | null;
}) => safeCapture("client_lane.approval_record_download_failed", props);
```

- [ ] **Step 4: `saveBlob` and the generic `useRequestActions`**

Create `src/lib/client-lane/recordPdf.ts`:

```ts
/**
 * Hand a blob to the browser as a download (the approval record, spec
 * 2026-10-06 §4.8): one anchor, clicked, removed, its URL revoked after.
 */
export function saveBlob(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.rel = "noopener";
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
}
```

In `src/components/client-lane/agency/useRequestActions.tsx`:

- Imports: add `FilePdf` to the phosphor import. Import `trackApprovalRecordDownloaded` and `trackApprovalRecordDownloadFailed`. Import `downloadApprovalRecord` and `type ApprovalSubject` from the service. Import `recordFilename` and `withdrawNote` from `@/lib/client-lane/subjectRequests`, and `saveBlob` from `@/lib/client-lane/recordPdf`.
- Signature and doc:

```ts
/**
 * Copy link, Open link, Download record, Resend and Withdraw for one approval
 * request of any subject — the Share dialog's request row and the top-bar
 * status list run the same verbs, toasts and analytics (spec 2026-10-01
 * §5.2, 2026-10-06 §5.1). Toasts through the selector only.
 */
export function useRequestActions(
  request: AgencyRequest,
  subject: ApprovalSubject
) {
  const showToast = useToastStore((s) => s.showToast);
  const qc = useQueryClient();
  const withdraw = useWithdrawApprovalRequest(subject.type, subject.id);
  const resend = useResendApprovalRequest();
  const [confirmingWithdraw, setConfirmingWithdraw] = useState(false);
  const open = request.status === "pending";
  const linkLive = request.share_link_active;
  const where = { subject_type: subject.type, request_number: request.number };
```

- In `copyLink` and `openLink`, `subject_type: "kv_file"` becomes `subject_type: subject.type`.
- In `doResend` / `doWithdraw`, every `track*` call spreads `...where` in place of `request_number: request.number`. The `round_closed` branch invalidates `approvalRequestsRoot(subject.type, subject.id)`.
- Add, before `const verbs`:

```ts
  /** The audit record (spec 2026-10-06 §4.8) — any status, agency side. */
  const downloadRecord = async () => {
    try {
      const pdf = await downloadApprovalRecord(request.id);
      saveBlob(pdf, recordFilename(subject.name, request.number));
      trackApprovalRecordDownloaded({
        subject_type: subject.type,
        side: "agency",
      });
    } catch (error) {
      const err = approvalApiError(error);
      trackApprovalRecordDownloadFailed({
        subject_type: subject.type,
        side: "agency",
        reason: failureReason(err),
        http_status: err.status,
      });
      showToast(
        "Couldn't download the record",
        err.message ?? "Try again in a moment.",
        "error"
      );
    }
  };
```

- In `verbs`, after the `open` verb:

```ts
    {
      id: "record",
      label: "Download record",
      icon: <FilePdf size={14} />,
      onSelect: () => void downloadRecord(),
    },
```

- The return object adds `downloadRecord`.
- `WithdrawConfirm` takes `note: string` in its props and renders `{note}` in place of the hard-coded artboards sentence.

- [ ] **Step 5: Update every existing caller so the tree compiles**

| File | Change |
|---|---|
| `agency/KvApprovalRequestsSection.tsx` | `useRequestActions(request, { type: "kv_file", id: fileId, name: "Key visual" })` (Task 5 passes the real subject); `<WithdrawConfirm note={withdrawNote("kv_file")} …/>`; `trackApprovalRequestFormOpened({ subject_type: "kv_file", source: "share_dialog", ready_total: total })`; `copyPersonal`'s `where` already says `subject_type: "kv_file"` |
| `agency/KvApprovalStatusList.tsx` | same `useRequestActions` subject literal; `WithdrawConfirm note={withdrawNote("kv_file")}`; `trackStatusRowJumped({ subject_type: "kv_file", surface, … })` |
| `agency/KvClientApprovalSlot.tsx` | `trackApprovalRequestFormOpened({ subject_type: "kv_file", … })`; `trackStatusChipOpened({ subject_type: "kv_file", … })` |
| `agency/KvRequestForm.tsx` | `trackApprovalRequestSent({ subject_type: "kv_file", … })`; `trackApprovalRequestSendFailed({ subject_type: "kv_file", … })`; `buildRequestPayload({ phases, … })` is unchanged (it is an array) |
| `agency/KvReadyForClientTray.tsx` | `trackApprovalRequestFormOpened({ subject_type: "kv_file", source: "tray", … })` |
| `DecisionPage.tsx` | `trackClientArtboardDecided({ subject_type: data.type, … })`, `trackClientRequestDecisionFailed({ subject_type: data.type, … })`, `trackClientRequestCompleted({ subject_type: data.type, … })`; add `data.type` to the `doSubmitRequest` `useCallback` deps (already listed) |

The `"Key visual"` literal is a placeholder that lives only until Tasks 5–6. Both callers are replaced there by components that receive the real subject. Note it in the track's session log.

- [ ] **Step 6: Run the test and the regression suites**

```bash
cd WT && bun test src/components/client-lane/agency/useRequestActions.test.tsx
cd WT && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
cd WT && bun test src/components/client-lane/DecisionPage.test.tsx
```

Expected: the new file is all green. The other two match their Task 0 baseline lists exactly.

- [ ] **Step 7: Mutation checks**
  - In `copyLink`, write `subject_type: "kv_file"`. "reports the deck's subject type when its link is copied" must FAIL. Restore.
  - Remove the `record` verb. "offers Download record on a closed request, and no Withdraw" must FAIL. Restore.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "downloads the record under the subject's name" — pass `subject.id` instead of `subject.name` to `recordFilename`.

- [ ] **Step 8: Gate + commit**

Run the tsc count and touched-path grep (as Task 1 Step 8, adding `useRequestActions|recordPdf|DecisionPage`), then eslint on touched files.

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): approval-request verbs and events name their subject

useRequestActions takes the subject and gains Download record; every
approval_request_*, status_chip_opened, status_row_jumped and request-link
client event carries subject_type; record download events added.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 4: `RequestForm` — shared form, KV items split out, deck/plan item row

**Files:**
- Create: `src/components/client-lane/agency/RequestForm.tsx`, `KvRequestItems.tsx`, `SubjectRequestItem.tsx`, `ItemThumb.tsx`
- Delete: `src/components/client-lane/agency/KvRequestForm.tsx` (`/usr/bin/git rm`)
- Modify: `src/components/client-lane/agency/RequestApprovalPanel.tsx` (`ApprovalSendStep` `versionLabel` prop)
- Modify: `src/components/studio/kv-generator/KvSharePanel.tsx` (import + JSX), `src/components/client-lane/agency/KvClientApprovalSlot.tsx` (import + JSX)
- Test: `src/components/client-lane/agency/RequestForm.test.tsx` (create)

**Interfaces:**
- Consumes:
  - Task 1: `ApprovalSubject`, `useApprovalRequestPreview(type, id)`, `useCreateApprovalRequest(type, id)`, `approvalRequestsRoot(type, id)`;
  - Task 2: `requestSelection`, `RequestSelection`, `requestBlockedReason`, `subjectItemLine`, `SUBJECT_NOUN`, `buildRequestPayload({ phases: … | null })`;
  - Task 3: `trackApprovalRequestSent` / `…SendFailed` with `subject_type`.
- Produces:
  - `RequestForm(props: RequestFormProps)` where `RequestFormProps = { subject: ApprovalSubject; brandId?: string | null; onDone: () => void; onCancel: () => void; initialEmails?: string[]; prefillMessage?: boolean; onSent?: (created: CreateApprovalRequestResponse) => void }`;
  - `ItemThumb({ subjectType, url, phase, className })`;
  - `ApprovalSendStep` accepts `versionLabel?: string | null`. When it is undefined, the old rule applies (a deck names `v{number}`).

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/agency/RequestForm.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  agencyRequest,
  deckApproval,
  deckPreviewItem,
  previewItem,
  requestApproval,
  requestPreview,
} from "@/lib/client-lane/requestFixtures";
import axiosInstance from "@/services/axios";
import type {
  ApprovalRequestPreview,
  CreateApprovalRequestResponse,
} from "@/services/client-lane";

import { RequestForm } from "./RequestForm";

const body = () => within(document.body);
const DECK = { type: "deck", id: "d1", name: "Ramadan 2027 strategy" } as const;
const KV = { type: "kv_file", id: "f1", name: "Ramadan hero" } as const;

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

/** The agency api edge — spied, never vi.mock'ed. */
function stub(
  preview: ApprovalRequestPreview,
  created?: CreateApprovalRequestResponse
) {
  vi.spyOn(axiosInstance, "get").mockImplementation((async (url: string) => {
    if (url === "v1/approval-requests/preview") {
      return { data: { data: preview } };
    }
    throw new Error(`unexpected GET ${url}`);
  }) as never);
  const post = vi
    .spyOn(axiosInstance, "post")
    .mockImplementation((async (url: string) => {
      if (url === "v1/approval-requests") return { data: { data: created } };
      throw new Error(`unexpected POST ${url}`);
    }) as never);
  const capture = vi
    .spyOn(posthog, "capture")
    .mockImplementation(() => undefined as never);
  return { post, capture };
}

function renderForm(subject: typeof DECK | typeof KV) {
  return render(
    <RequestForm
      subject={subject}
      brandId={null}
      onDone={vi.fn()}
      onCancel={vi.fn()}
    />,
    { wrapper: Wrapper }
  );
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("RequestForm — deck (spec 2026-10-06 §5.1)", () => {
  it("shows a deck as one item with the version it replaces", async () => {
    stub(
      requestPreview([
        deckPreviewItem({ replaces: { request_number: null, round: 3 } }),
      ])
    );
    renderForm(DECK);
    expect(
      await body().findByText("v4 · replaces v3, still waiting")
    ).toBeInTheDocument();
    expect(body().getByText("Ramadan 2027 strategy")).toBeInTheDocument();
    expect(body().queryByText("Phases")).toBeNull();
  });

  it("sends a deck request without kv_phases", async () => {
    const { post, capture } = stub(requestPreview([deckPreviewItem()]), {
      request: agencyRequest({ approvals: [deckApproval()] }),
      share_url: "https://app.test/s/req1",
      approvers: [],
    });
    renderForm(DECK);
    fireEvent.click(
      await body().findByRole("button", { name: "Send request" })
    );
    await waitFor(() => expect(post).toHaveBeenCalled());
    expect(post.mock.calls[0][0]).toBe("v1/approval-requests");
    expect(post.mock.calls[0][1]).toEqual({
      subject_type: "deck",
      subject_id: "d1",
      approver_emails: [],
    });
    expect(
      await body().findByText("Request 1 is out for approval")
    ).toBeInTheDocument();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_sent",
      expect.objectContaining({ subject_type: "deck", phases: [] })
    );
  });

  it("refuses to send a brand-less deck and says why", async () => {
    stub(requestPreview([], { blocked_reason: "no_brand" }));
    renderForm(DECK);
    expect(
      await body().findByText("Link this deck to a brand to request approval")
    ).toBeInTheDocument();
    expect(body().getByRole("button", { name: "Send request" })).toBeDisabled();
  });
});

describe("RequestForm — KV regression", () => {
  it("still sends the phases a KV request was built from", async () => {
    const { post } = stub(requestPreview([previewItem()]), {
      request: agencyRequest({ approvals: [requestApproval()] }),
      share_url: "https://app.test/s/req1",
      approvers: [],
    });
    renderForm(KV);
    expect(await body().findByText("Phases")).toBeInTheDocument();
    fireEvent.click(body().getByRole("button", { name: "Send request" }));
    await waitFor(() => expect(post).toHaveBeenCalled());
    expect(post.mock.calls[0][1]).toEqual({
      subject_type: "kv_file",
      subject_id: "f1",
      kv_phases: ["craft"],
      approver_emails: [],
    });
  });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/components/client-lane/agency/RequestForm.test.tsx
```

Expected: the file errors at import (`Cannot find module './RequestForm'`) and reports `1 error`.

- [ ] **Step 3: `ItemThumb` and `SubjectRequestItem`**

Create `src/components/client-lane/agency/ItemThumb.tsx`:

```tsx
import { ChartBar, Presentation } from "@phosphor-icons/react";
import clsx from "clsx";

import type { ShareSubjectType } from "@/lib/client-lane/types";
import type { KvSharePhase } from "@/types/kv/share-link";

import { KvArtboardThumb } from "./KvArtboardThumb";

/**
 * One request item's picture in the agency surfaces (spec 2026-10-06 §5.1
 * "the thumbnail is a slot"): KV keeps `KvArtboardThumb`; a deck or plan
 * shows its preview image, or its type icon when it has none.
 */
export function ItemThumb({
  subjectType,
  url,
  phase,
  className,
}: {
  subjectType: ShareSubjectType;
  url: string | null;
  phase: KvSharePhase | null;
  /** Size classes, e.g. `size-8`. */
  className: string;
}) {
  if (subjectType === "kv_file") {
    return <KvArtboardThumb url={url} phase={phase} className={className} />;
  }
  if (url) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={url}
        alt=""
        className={clsx("shrink-0 rounded-md object-cover", className)}
      />
    );
  }
  const Icon = subjectType === "deck" ? Presentation : ChartBar;
  return (
    <span
      aria-hidden
      className={clsx(
        "flex shrink-0 items-center justify-center rounded-md bg-white/5 text-icon-inverse-subtlest",
        className
      )}
    >
      <Icon size={16} />
    </span>
  );
}
```

Create `src/components/client-lane/agency/SubjectRequestItem.tsx`:

```tsx
import { subjectItemLine } from "@/lib/client-lane/subjectRequests";
import type { ShareSubjectType } from "@/lib/client-lane/types";
import type { ApprovalRequestPreviewItem } from "@/services/client-lane";

import { ItemThumb } from "./ItemThumb";

/** A deck / plan request's one item (spec §5.1): thumbnail, title, and
 *  "v4 · replaces v3, still waiting". */
export function SubjectRequestItem({
  subjectType,
  title,
  item,
}: {
  subjectType: ShareSubjectType;
  title: string;
  item: ApprovalRequestPreviewItem;
}) {
  const line = subjectItemLine(item);
  return (
    <div className="flex items-center gap-2.5 font-geist">
      <ItemThumb
        subjectType={subjectType}
        url={item.thumbnail_url}
        phase={item.phase}
        className="size-10"
      />
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-textSm text-text-inverse">{title}</span>
        {line && (
          <span className="truncate text-textXs text-text-inverse-subtle">
            {line}
          </span>
        )}
      </span>
    </div>
  );
}
```

- [ ] **Step 4: `KvRequestItems` — the KV part, moved**

Create `src/components/client-lane/agency/KvRequestItems.tsx` with this header and component, then MOVE `ArtboardsFold` and `ListFold` from `KvRequestForm.tsx` into it verbatim (as private functions). Their only change is already in place from Task 1: keys `subject_key ?? version_id`.

```tsx
"use client";

import { CaretDown } from "@phosphor-icons/react";
import clsx from "clsx";
import { useId, useState } from "react";

import { FilterChips } from "@/components/frndos/v2";
import { plural, replacesNote } from "@/lib/client-lane/requests";
import type { RequestSelection } from "@/lib/client-lane/subjectRequests";
import type {
  ApprovalRequestPreview,
  ApprovalRequestPreviewItem,
} from "@/services/client-lane";
import { KV_SHARE_PHASE_LABEL, type KvSharePhase } from "@/types/kv/share-link";

import { SendTagPill } from "../StatusPill";
import { KvArtboardThumb } from "./KvArtboardThumb";

const EYEBROW =
  "font-geist text-textXsMedium uppercase tracking-wider text-text-inverse-subtlest";

/**
 * The KV half of the request form (spec 2026-10-01 §5.2): phase pills with
 * counts, the artboards this request sends, and the "Already approved" /
 * "Waiting" folds. The form owns which phases are off.
 */
export function KvRequestItems({
  preview,
  selection,
  onToggle,
}: {
  preview: ApprovalRequestPreview;
  selection: RequestSelection;
  onToggle: (phase: KvSharePhase) => void;
}) {
  return (
    <section className="flex flex-col gap-2">
      <h3 className={EYEBROW}>Phases</h3>
      <FilterChips
        selection="multiple"
        ariaLabel="Phases to send"
        values={selection.phases}
        onToggle={onToggle}
        options={preview.phases.map((p) => ({
          value: p.phase,
          label: KV_SHARE_PHASE_LABEL[p.phase],
          count: p.count,
        }))}
      />
      {selection.phases.length === 0 ? (
        <p className="text-textXs text-text-inverse-subtle">
          Pick at least one phase.
        </p>
      ) : (
        <ArtboardsFold items={selection.items} />
      )}
      <ListFold
        label="Already approved"
        rows={selection.approved.map((a) => ({
          key: a.subject_key ?? a.version_id,
          text: a.label,
        }))}
      />
      <ListFold
        label="Waiting"
        rows={selection.waiting.map((w) => ({
          key: w.subject_key ?? w.version_id,
          text: `${w.label} — in Request ${w.request_number}`,
        }))}
      />
    </section>
  );
}
```

- [ ] **Step 5: `RequestForm` — the shared form**

Create `src/components/client-lane/agency/RequestForm.tsx`:

```tsx
"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useId, useState } from "react";

import { AutoGrowTextarea, Button } from "@/components/frndos/v2";
import {
  failureReason,
  trackApprovalRequestSendFailed,
  trackApprovalRequestSent,
} from "@/lib/analytics/client-lane-events";
import { requestDefaultMessage } from "@/lib/client-lane/canvasApproval";
import { buildRequestPayload } from "@/lib/client-lane/requests";
import {
  SUBJECT_NOUN,
  requestBlockedReason,
  requestSelection,
} from "@/lib/client-lane/subjectRequests";
import {
  approvalApiError,
  approvalRequestsRoot,
  useApprovalRequestPreview,
  useCreateApprovalRequest,
  type ApprovalSubject,
  type CreateApprovalRequestResponse,
} from "@/services/client-lane";
import { useToastStore } from "@/store/useToast";
import type { KvSharePhase } from "@/types/kv/share-link";

import { ApproverEmailsField } from "./ApproverEmailsField";
import { DecideByField } from "./DecideByField";
import { KvRequestItems } from "./KvRequestItems";
import { ApprovalSendStep } from "./RequestApprovalPanel";
import { SubjectRequestItem } from "./SubjectRequestItem";
import { useApproverEmails } from "./useApproverEmails";
import { useArtboardThumbnailSync } from "./useArtboardThumbnailSync";

const MAX_MESSAGE = 500;
const EYEBROW =
  "font-geist text-textXsMedium uppercase tracking-wider text-text-inverse-subtlest";
const TEXTAREA =
  "rounded-xl border border-white/10 bg-white/5 px-3 py-2.5 font-geist text-textSm text-text-inverse outline-none transition-all duration-200 ease-out placeholder:text-text-inverse-subtlest focus:border-white/20 focus:ring-0 focus-visible:ring-2 focus-visible:ring-white/40";

export interface RequestFormProps {
  subject: ApprovalSubject;
  brandId?: string | null;
  onDone: () => void;
  onCancel: () => void;
  /** Prefilled approvers (top-bar form: the subject's last request's). */
  initialEmails?: string[];
  /** KV only: prefill the message from the phase pills until the user types. */
  prefillMessage?: boolean;
  /** Fired once the request exists — hosts refresh what it changed (a
   *  plan's lifecycle status). */
  onSent?: (created: CreateApprovalRequestResponse) => void;
}

/**
 * The request form for every subject (spec 2026-10-06 §5.1) followed by the
 * send step. Shared: approvers, message, Decide by, send step. KV adds the
 * phase pills and folds (`KvRequestItems`); a deck or plan shows its one
 * item. Rendered INLINE by dialogs (nesting dialogs breaks focus trapping).
 */
export function RequestForm({
  subject,
  brandId,
  onDone,
  onCancel,
  initialEmails,
  prefillMessage,
  onSent,
}: RequestFormProps) {
  const [result, setResult] = useState<CreateApprovalRequestResponse | null>(
    null
  );

  if (result) {
    const round = result.request.approvals[0]?.round;
    return (
      <ApprovalSendStep
        result={{
          share_url: result.share_url,
          message: result.request.message,
          number: result.request.number,
          approvers: result.approvers,
        }}
        title={subject.name}
        subjectType={subject.type}
        // A deck's request names its version (v4), not the request number.
        versionLabel={subject.type === "deck" && round ? `v${round}` : null}
        headline={`Request ${result.request.number} is out for approval`}
        onDone={onDone}
      />
    );
  }

  return (
    <RequestFields
      subject={subject}
      brandId={brandId}
      onSent={(created) => {
        onSent?.(created);
        setResult(created);
      }}
      onCancel={onCancel}
      initialEmails={initialEmails}
      prefillMessage={prefillMessage}
    />
  );
}

function RequestFields({
  subject,
  brandId,
  onSent,
  onCancel,
  initialEmails,
  prefillMessage,
}: {
  subject: ApprovalSubject;
  brandId?: string | null;
  onSent: (created: CreateApprovalRequestResponse) => void;
  onCancel: () => void;
  initialEmails?: string[];
  prefillMessage?: boolean;
}) {
  const showToast = useToastStore((s) => s.showToast);
  const qc = useQueryClient();
  const isKv = subject.type === "kv_file";
  const preview = useApprovalRequestPreview(subject.type, subject.id);
  useArtboardThumbnailSync(isKv ? subject.id : null, preview.data?.items ?? []);
  const create = useCreateApprovalRequest(subject.type, subject.id);
  const approvers = useApproverEmails(brandId, initialEmails);
  // KV phases are ON unless turned off — a phase that becomes ready while
  // the form is open joins the request rather than hiding behind a dead pill.
  const [off, setOff] = useState<KvSharePhase[]>([]);
  const [message, setMessage] = useState<string | null>(null);
  const [decideBy, setDecideBy] = useState("");
  const messageId = useId();

  if (preview.isLoading) {
    return (
      <p className="font-geist text-textXs text-text-inverse-subtlest">
        Loading what&apos;s ready…
      </p>
    );
  }
  if (preview.isError || !preview.data) {
    return (
      <div className="flex flex-col items-start gap-2 font-geist">
        <p className="text-textXs text-text-inverse-subtle">
          Couldn&apos;t load what&apos;s ready to send.
        </p>
        <Button
          type="button"
          variant="secondary"
          size="small"
          onClick={() => void preview.refetch()}
        >
          Try again
        </Button>
      </div>
    );
  }

  const data = preview.data;
  const selection = requestSelection(data, off);
  const items = selection.items;
  const blocked = isKv ? null : requestBlockedReason(subject.type, data, true);
  const messageValue =
    message ?? (prefillMessage && isKv ? requestDefaultMessage(items) : "");
  /** Another request was created first, or marks moved: re-read the
   *  preview AND the request list. */
  const reread = () =>
    void qc.invalidateQueries({
      queryKey: approvalRequestsRoot(subject.type, subject.id),
    });

  const toggle = (phase: KvSharePhase) =>
    setOff((prev) =>
      prev.includes(phase) ? prev.filter((p) => p !== phase) : [...prev, phase]
    );

  const submit = () => {
    if (create.isPending) return;
    const emails = approvers.commit();
    if (emails === null || items.length === 0) return;
    if (isKv && selection.phases.length === 0) return;
    const payload = buildRequestPayload({
      phases: isKv ? selection.phases : null,
      emails,
      message: messageValue,
      decideBy,
    });
    create.mutate(payload, {
      onSuccess: (created) => {
        trackApprovalRequestSent({
          subject_type: subject.type,
          request_number: created.request.number,
          artboard_count: created.request.approvals.length,
          phases: payload.kv_phases ?? [],
          approver_count: emails.length,
          has_deadline: Boolean(payload.decide_by),
        });
        onSent(created);
      },
      onError: (error) => {
        const err = approvalApiError(error);
        trackApprovalRequestSendFailed({
          subject_type: subject.type,
          reason: failureReason(err),
          http_status: err.status,
        });
        if (err.code === "already_a_member") {
          approvers.setError(
            `${err.email ?? "That address"} is already a member of this workspace — they can approve from inside frndOS.`
          );
          return;
        }
        if (err.code === "no_brand") {
          showToast(
            "This can't be sent yet",
            `Link this ${SUBJECT_NOUN[subject.type].one} to a brand to request approval.`,
            "error"
          );
          reread();
          return;
        }
        if (err.code === "nothing_ready") {
          showToast(
            "Nothing new to send",
            isKv
              ? "Everything in those phases is approved, waiting, or no longer marked ready. Mark an artboard on the canvas, then send again."
              : "This version is already approved or waiting. Change something, then send again.",
            "error"
          );
          reread();
          return;
        }
        if (err.code === "round_conflict") {
          showToast(
            "Someone else just sent a request",
            "What's ready has changed — check the list and send again.",
            "error"
          );
          reread();
          return;
        }
        if (err.code === "too_many_items") {
          showToast(
            "Too many artboards for one request",
            `A request holds up to ${err.max ?? 50} artboards — pick fewer phases.`,
            "error"
          );
          return;
        }
        showToast(
          "Couldn't send the request",
          err.message ?? "Try again in a moment.",
          "error"
        );
      },
    });
  };

  return (
    <form
      className="flex flex-col gap-5 font-geist"
      onSubmit={(e) => {
        e.preventDefault();
        submit();
      }}
    >
      <span className="text-textSmMedium text-text-inverse">
        Request approval
      </span>

      {isKv ? (
        <KvRequestItems preview={data} selection={selection} onToggle={toggle} />
      ) : (
        <section className="flex flex-col gap-2">
          <h3 className={EYEBROW}>{SUBJECT_NOUN[subject.type].label}</h3>
          {items.map((item) => (
            <SubjectRequestItem
              key={item.subject_key ?? item.version_id ?? "whole"}
              subjectType={subject.type}
              title={subject.name}
              item={item}
            />
          ))}
          {blocked && (
            <p className="text-textXs text-text-inverse-subtle">{blocked}</p>
          )}
        </section>
      )}

      <section className="flex flex-col gap-2">
        <h3 className={EYEBROW}>Approvers · optional</h3>
        <ApproverEmailsField
          approvers={approvers}
          disabled={create.isPending}
        />
      </section>

      <section className="flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <label htmlFor={messageId} className={EYEBROW}>
            Message · optional
          </label>
          <span className="text-textXs text-text-inverse-subtlest">
            {messageValue.length}/{MAX_MESSAGE}
          </span>
        </div>
        <AutoGrowTextarea
          id={messageId}
          rows={3}
          maxLength={MAX_MESSAGE}
          value={messageValue}
          onChange={(e) => setMessage(e.target.value)}
          aria-label="Message"
          placeholder={
            isKv
              ? "Craft 1 · Resize 5 — the TikTok cut is new since Tuesday."
              : "What changed since the last version?"
          }
          className={TEXTAREA}
        />
      </section>

      <section className="flex flex-col gap-2">
        <h3 className={EYEBROW}>Decide by · optional</h3>
        <DecideByField
          value={decideBy}
          onChange={setDecideBy}
          disabled={create.isPending}
        />
      </section>

      <div className="flex items-center gap-2">
        <Button
          type="submit"
          size="small"
          loading={create.isPending}
          disabled={create.isPending || items.length === 0}
        >
          Send request
        </Button>
        <Button
          type="button"
          variant="secondary"
          size="small"
          onClick={onCancel}
        >
          Cancel
        </Button>
      </div>
    </form>
  );
}
```

In `RequestApprovalPanel.tsx` `ApprovalSendStep`, add the prop and use it:

```tsx
  /** Overrides the version the send-step text names (a deck request: its
   *  approval's round, not the request number). Undefined keeps the old rule. */
  versionLabel?: string | null;
```

```tsx
  const resolvedVersion =
    versionLabel !== undefined
      ? versionLabel
      : subjectType === "deck"
        ? `v${result.number}`
        : null;
```

Then use `resolvedVersion` wherever the body used `versionLabel` (the `sendMessage(...)` call, the headline fallback and `mailtoHref(...)`). Destructure the prop as `versionLabel` in the parameter list.

- [ ] **Step 6: Swap the two KV hosts and delete the old form**

`KvSharePanel.tsx`: `import { RequestForm } from "@/components/client-lane/agency/RequestForm";` replaces the `KvRequestForm` import. The `requesting` branch renders:

```tsx
      <RequestForm
        subject={{ type: "kv_file", id: fileId, name: fileName }}
        brandId={brandId}
        onDone={() => setRequesting(false)}
        onCancel={() => setRequesting(false)}
      />
```

`KvClientApprovalSlot.tsx`: the same import swap. Its `<KvRequestForm fileId={fileId} fileName={fileName} …>` becomes `<RequestForm subject={{ type: "kv_file", id: fileId, name: fileName }} brandId={brandId} initialEmails={lastRequestEmails(list)} prefillMessage onDone={…} onCancel={…} />`.

```bash
cd WT && /usr/bin/git rm -q src/components/client-lane/agency/KvRequestForm.tsx && /usr/bin/grep -rn "KvRequestForm" src || echo "no references left"
```

Expected: `no references left`. If a doc comment mentions it (`RequestApprovalPanel.tsx:35`), reword it to `RequestForm`.

- [ ] **Step 7: Run the tests and regressions**

```bash
cd WT && bun test src/components/client-lane/agency/RequestForm.test.tsx
cd WT && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: `RequestForm.test.tsx` is all green. `KvSharePanel.test.tsx` matches its Task 0 baseline list exactly.

- [ ] **Step 8: Mutation checks**
  - In `RequestFields`, change `isKv ? <KvRequestItems …/> : …` to always render `KvRequestItems`. "shows a deck as one item with the version it replaces" must FAIL. Restore.
  - Pass `phases: selection.phases` for every subject. "sends a deck request without kv_phases" must FAIL. Restore.
  - Delete `blocked && …`. "refuses to send a brand-less deck and says why" must FAIL. Restore.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "still sends the phases a KV request was built from" — pass `phases: null` for every subject.

- [ ] **Step 9: Gate + commit** (tsc count + grep `client-lane/agency|KvSharePanel`, eslint on touched files)

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
refactor(web): one request form for KV, deck and plan

RequestForm keeps approvers, message, Decide by and the send step;
KvRequestItems holds the phase pills and folds; a deck or plan shows one
item row with the version it replaces. KV posts the same payload.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 5: `ApprovalRequestsSection` + `ApprovalStatusList` — generic

**Files:**
- Rename + modify: `src/components/client-lane/agency/KvApprovalRequestsSection.tsx` → `ApprovalRequestsSection.tsx`
- Rename + modify: `src/components/client-lane/agency/KvApprovalStatusList.tsx` → `ApprovalStatusList.tsx`
- Modify: `src/components/client-lane/agency/RequestLinkRow.test.tsx` (import path), `src/components/studio/kv-generator/KvSharePanel.tsx` (import + JSX), `src/components/client-lane/agency/KvClientApprovalSlot.tsx` (import + JSX)
- Test: `src/components/client-lane/agency/ApprovalRequestsSection.test.tsx`, `src/components/client-lane/agency/ApprovalStatusList.test.tsx` (create)

**Interfaces:**
- Consumes:
  - Task 1 hooks;
  - Task 2 `subjectRequestTitle`, `requestBlockedReason`, `itemMeta`, `withdrawNote`;
  - Task 3 `useRequestActions(request, subject)`, `WithdrawConfirm` `note`;
  - Task 4 `ItemThumb`.
- Produces:
  - `ApprovalRequestsSection({ subject: ApprovalSubject; open: boolean; hasReadyMarks?: boolean /* default true; KV passes its marks */; onRequest: () => void })`;
  - `RequestLinkRow` is still exported from `ApprovalRequestsSection.tsx`;
  - `ApprovalStatusList({ requests: AgencyRequest[]; subject: ApprovalSubject; surface: ApprovalSurface; onJump?: (approval: AgencyRequestApproval) => void })`. A row is a button only when `onJump` is given.

- [ ] **Step 1: Rename with history**

```bash
cd WT && /usr/bin/git mv src/components/client-lane/agency/KvApprovalRequestsSection.tsx src/components/client-lane/agency/ApprovalRequestsSection.tsx && /usr/bin/git mv src/components/client-lane/agency/KvApprovalStatusList.tsx src/components/client-lane/agency/ApprovalStatusList.tsx
```

In `RequestLinkRow.test.tsx`, change `from "./KvApprovalRequestsSection"` to `from "./ApprovalRequestsSection"`. Leave the component names inside the files as they are for now: Step 2's tests import the NEW names, so they fail.

- [ ] **Step 2: Write the failing tests**

Create `src/components/client-lane/agency/ApprovalRequestsSection.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  agencyRequest,
  deckApproval,
  deckPreviewItem,
  requestPreview,
} from "@/lib/client-lane/requestFixtures";
import axiosInstance from "@/services/axios";
import type {
  AgencyRequest,
  ApprovalRequestPreview,
} from "@/services/client-lane";

import { ApprovalRequestsSection } from "./ApprovalRequestsSection";

const body = () => within(document.body);
const DECK = { type: "deck", id: "d1", name: "Ramadan 2027 strategy" } as const;
const KV = { type: "kv_file", id: "f1", name: "Ramadan hero" } as const;

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function stub(preview: ApprovalRequestPreview, list: AgencyRequest[]) {
  vi.spyOn(axiosInstance, "get").mockImplementation((async (url: string) => {
    if (url === "v1/approval-requests/preview") {
      return { data: { data: preview } };
    }
    if (url === "v1/approval-requests") return { data: { data: list } };
    throw new Error(`unexpected GET ${url}`);
  }) as never);
  return vi
    .spyOn(posthog, "capture")
    .mockImplementation(() => undefined as never);
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("ApprovalRequestsSection (spec 2026-10-06 §5.2–5.3)", () => {
  it("disables Request approval on a brand-less deck and says why", async () => {
    stub(requestPreview([], { blocked_reason: "no_brand" }), []);
    render(
      <ApprovalRequestsSection subject={DECK} open onRequest={vi.fn()} />,
      { wrapper: Wrapper }
    );
    expect(
      await body().findByText("Link this deck to a brand to request approval")
    ).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Request approval" })
    ).toBeDisabled();
  });

  it("opens a deck's form and reports the subject type", async () => {
    const capture = stub(requestPreview([deckPreviewItem()]), []);
    const onRequest = vi.fn();
    render(
      <ApprovalRequestsSection subject={DECK} open onRequest={onRequest} />,
      { wrapper: Wrapper }
    );
    const button = await body().findByRole("button", {
      name: "Request approval",
    });
    await waitFor(() => expect(button).not.toBeDisabled());
    fireEvent.click(button);
    expect(onRequest).toHaveBeenCalled();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_form_opened",
      expect.objectContaining({ subject_type: "deck", source: "share_dialog" })
    );
  });

  it("titles a deck request by its version, not by artboards", async () => {
    stub(requestPreview([]), [
      agencyRequest({ number: 2, approvals: [deckApproval()] }),
    ]);
    render(
      <ApprovalRequestsSection subject={DECK} open onRequest={vi.fn()} />,
      { wrapper: Wrapper }
    );
    expect(await body().findByText("Request 2 · v4")).toBeInTheDocument();
  });

  it("keeps KV's reason when nothing is marked ready", async () => {
    stub(requestPreview([]), []);
    render(
      <ApprovalRequestsSection
        subject={KV}
        open
        hasReadyMarks={false}
        onRequest={vi.fn()}
      />,
      { wrapper: Wrapper }
    );
    expect(
      await body().findByText("Mark artboards ready on the canvas first")
    ).toBeInTheDocument();
  });
});
```

Create `src/components/client-lane/agency/ApprovalStatusList.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  agencyRequest,
  deckApproval,
} from "@/lib/client-lane/requestFixtures";

import { ApprovalStatusList } from "./ApprovalStatusList";

const body = () => within(document.body);
const DECK = { type: "deck", id: "d1", name: "Ramadan 2027 strategy" } as const;
const PLAN = { type: "campaign", id: "p1", name: "Q4 media plan" } as const;

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("ApprovalStatusList — deck and plan rows", () => {
  it("shows a deck's pins without a decision as feedback", () => {
    render(
      <ApprovalStatusList
        requests={[agencyRequest({ approvals: [deckApproval({ pin_count: 2 })] })]}
        subject={DECK}
        surface="deck"
        onJump={vi.fn()}
      />,
      { wrapper: Wrapper }
    );
    expect(
      body().getByText("Feedback, no decision yet · 2 pins")
    ).toBeInTheDocument();
  });

  it("opens the deck's pins from its row and reports the subject type", () => {
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const onJump = vi.fn();
    render(
      <ApprovalStatusList
        requests={[agencyRequest({ approvals: [deckApproval()] })]}
        subject={DECK}
        surface="deck"
        onJump={onJump}
      />,
      { wrapper: Wrapper }
    );
    fireEvent.click(body().getByRole("button", { name: "Show pins on Deck" }));
    expect(onJump).toHaveBeenCalledWith(
      expect.objectContaining({ id: "apr_d" })
    );
    expect(capture).toHaveBeenCalledWith(
      "client_lane.status_row_jumped",
      expect.objectContaining({ subject_type: "deck", surface: "deck", phase: null })
    );
  });

  it("draws a plan row as text when there is nowhere to jump", () => {
    render(
      <ApprovalStatusList
        requests={[
          agencyRequest({
            approvals: [deckApproval({ label: "Campaign plan", round: 2 })],
          }),
        ]}
        subject={PLAN}
        surface="plan"
      />,
      { wrapper: Wrapper }
    );
    expect(body().getByText("Campaign plan")).toBeInTheDocument();
    expect(body().queryByRole("button", { name: /^Show / })).toBeNull();
  });
});
```

- [ ] **Step 3: Run them to see them fail**

```bash
cd WT && bun test src/components/client-lane/agency/ApprovalRequestsSection.test.tsx
cd WT && bun test src/components/client-lane/agency/ApprovalStatusList.test.tsx
```

Expected: both FAIL. `ApprovalRequestsSection` / `ApprovalStatusList` are not exported (the files still export the `Kv*` names), so every test errors with "is not a function" or "undefined component".

- [ ] **Step 4: Make `ApprovalRequestsSection` generic**

In `ApprovalRequestsSection.tsx`:

- Imports:
  - drop `KvArtboardThumb`, `requestTitle` and `useRequestActions`'s old shape;
  - add `ItemThumb` from `./ItemThumb`, `withdrawNote`, `subjectRequestTitle` and `requestBlockedReason` from `@/lib/client-lane/subjectRequests`, and `type ApprovalSubject` from the service;
  - keep `plural` and `requestRowDescription`.
- The component:

```tsx
/**
 * The share dialog's "Approval requests" section (spec 2026-10-01 §5.2;
 * 2026-10-06 §5.1–5.3 for decks and plans): the way into a request and the
 * state of every request on the subject. Reads the same list the top-bar
 * slot reads, so their counts agree.
 */
export function ApprovalRequestsSection({
  subject,
  open,
  hasReadyMarks = true,
  onRequest,
}: {
  subject: ApprovalSubject;
  /** Gate the queries — only while the dialog is open. */
  open: boolean;
  /** KV: anything on the file marked ready (the reason tells them apart). */
  hasReadyMarks?: boolean;
  onRequest: () => void;
}) {
  const isKv = subject.type === "kv_file";
  const preview = useApprovalRequestPreview(subject.type, subject.id, {
    enabled: open,
  });
  const requests = useApprovalRequests(subject.type, subject.id, {
    enabled: open,
  });
  const total = preview.data?.total ?? 0;
  // Said in words, not a hover hint: a disabled reason has to be readable
  // on touch and by keyboard too (spec §5.2 "it says why").
  const reason = requestBlockedReason(subject.type, preview.data, hasReadyMarks);
  const list = requests.data ?? [];

  return (
    <section className="flex flex-col gap-2">
      <ShareSectionLabel
        trailing={
          <Button
            size="small"
            disabled={preview.isLoading || total === 0}
            onClick={() => {
              trackApprovalRequestFormOpened({
                subject_type: subject.type,
                source: "share_dialog",
                ready_total: total,
              });
              onRequest();
            }}
          >
            {isKv && total > 0
              ? `Request approval · ${total} new ready`
              : "Request approval"}
          </Button>
        }
      >
        Approval requests
      </ShareSectionLabel>
      {reason && <p className={QUIET}>{reason}</p>}
      {list.length > 0 ? (
        <ul className="flex flex-col gap-1">
          {list.map((request) => (
            <li key={request.id}>
              <RequestRow request={request} subject={subject} />
            </li>
          ))}
        </ul>
      ) : requests.isSuccess ? (
        <p className={QUIET}>No requests yet.</p>
      ) : null}
    </section>
  );
}
```

- `RequestRow({ request, subject })`:
  - `const actions = useRequestActions(request, subject); const title = subjectRequestTitle(request, subject.type); const isKv = subject.type === "kv_file";`
  - the disclosure's `aria-label`: `` `${expanded ? "Hide" : "Show"} ${isKv ? "artboards" : "details"} in Request ${request.number}` ``;
  - `<WithdrawConfirm note={withdrawNote(subject.type)} … />`;
  - pass `subjectType={subject.type}` to `RequestDetail`.
- `RequestDetail` takes `subjectType: ShareSubjectType`:
  - `copyPersonal`'s `where` becomes `{ subject_type: subjectType, round: request.number }`;
  - the items list `aria-label` becomes `` `${subjectType === "kv_file" ? "Artboards" : "Items"} in Request ${request.number}` ``;
  - it renders `<ItemRowDetail key={approval.id} approval={approval} subjectType={subjectType} />`.
- Rename `ArtboardRow` → `ItemRowDetail({ approval, subjectType })`:
  - replace `<KvArtboardThumb … />` with `<ItemThumb subjectType={subjectType} url={approval.thumbnail_url} phase={approval.phase} className="size-8" />`;
  - the label reads `{subjectType === "kv_file" ? approval.label : `${approval.label} · v${approval.round}`}`;
  - the rest is unchanged.
- `RequestLinkRow` is unchanged.

- [ ] **Step 5: Make `ApprovalStatusList` generic**

In `ApprovalStatusList.tsx`:

- Imports:
  - drop `KvArtboardThumb`, `artboardWho`, `plural` and `requestTitle`;
  - add `ItemThumb`, `itemMeta`, `subjectRequestTitle` and `withdrawNote`;
  - add `type ApprovalSubject` and `type ShareSubjectType`.
- The export:

```tsx
/**
 * The body of the top-bar status popover (spec 2026-10-01 §6.1; 2026-10-06
 * §5.1): every request on the subject — open first — with one row per item
 * (verdict, who, when, pins; "Feedback, no decision yet" for pins without a
 * decision). A row jumps only when the host can go somewhere: KV to the
 * artboard, a deck to its pins in the Comments dock. A plan has nowhere.
 */
export function ApprovalStatusList({
  requests,
  subject,
  surface,
  onJump,
}: {
  requests: AgencyRequest[];
  subject: ApprovalSubject;
  surface: ApprovalSurface;
  onJump?: (approval: AgencyRequestApproval) => void;
}) {
```

  Its body is unchanged except that each item renders `<StatusRequest … subject={subject} />`.
- `StatusRequest`:
  - `useRequestActions(request, subject)`, `title = subjectRequestTitle(request, subject.type)`;
  - `openLabel` says `"artboards"` for KV and `"details"` otherwise;
  - the list `aria-label` follows the same rule as Step 4;
  - `<WithdrawConfirm note={withdrawNote(subject.type)} …/>`;
  - each row:

```tsx
            <li key={approval.id}>
              <ItemStatusRow
                approval={approval}
                subjectType={subject.type}
                onJump={
                  onJump
                    ? () => {
                        trackStatusRowJumped({
                          subject_type: subject.type,
                          surface,
                          phase: approval.phase,
                          status: approval.status,
                          replaced:
                            approval.superseded_by_request_number !== null,
                        });
                        onJump(approval);
                      }
                    : undefined
                }
              />
            </li>
```

- Replace `ArtboardJumpRow` with `ItemStatusRow`:

```tsx
function ItemStatusRow({
  approval,
  subjectType,
  onJump,
}: {
  approval: AgencyRequestApproval;
  subjectType: ShareSubjectType;
  onJump?: () => void;
}) {
  const meta = itemMeta(approval);
  const content = (
    <>
      <ItemThumb
        subjectType={subjectType}
        url={approval.thumbnail_url}
        phase={approval.phase}
        className="size-8"
      />
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-textXs text-text-inverse">
          {approval.label}
        </span>
        {meta && (
          <span className="truncate text-textXs text-text-inverse-subtlest">
            {meta}
          </span>
        )}
      </span>
      {approval.superseded_by_request_number !== null ? (
        <span className={clsx("shrink-0", QUIET)}>
          Replaced in Request {approval.superseded_by_request_number}
        </span>
      ) : (
        <StatusPill status={approval.status} />
      )}
    </>
  );
  const row =
    "flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left font-geist";
  if (!onJump) return <div className={row}>{content}</div>;
  return (
    <button
      type="button"
      onClick={onJump}
      aria-label={
        subjectType === "kv_file"
          ? `Show ${approval.label} on the canvas`
          : `Show pins on ${approval.label}`
      }
      className={clsx(
        row,
        "outline-none transition-all duration-200 ease-out hover:bg-white/5 focus-visible:ring-2 focus-visible:ring-white/40"
      )}
    >
      {content}
    </button>
  );
}
```

- [ ] **Step 6: Swap the KV hosts**

- `KvSharePanel.tsx`: import `ApprovalRequestsSection` from `@/components/client-lane/agency/ApprovalRequestsSection`. The JSX becomes `<ApprovalRequestsSection subject={{ type: "kv_file", id: fileId, name: fileName }} open={open} hasReadyMarks={canCreateLink} onRequest={() => setRequesting(true)} />`.
- `KvClientApprovalSlot.tsx`: import `ApprovalStatusList` from `./ApprovalStatusList`. Its popover renders `<ApprovalStatusList requests={list} subject={{ type: "kv_file", id: fileId, name: fileName }} surface={surface} onJump={…} />`.

```bash
cd WT && /usr/bin/grep -rn "KvApprovalRequestsSection\|KvApprovalStatusList\|\"Key visual\" }" src || echo "clean"
```

Expected: `clean`. The Task 3 `"Key visual"` placeholders lived in the two renamed files and are gone with Step 4/5.

- [ ] **Step 7: Run tests and regressions**

```bash
cd WT && bun test src/components/client-lane/agency/ApprovalRequestsSection.test.tsx
cd WT && bun test src/components/client-lane/agency/ApprovalStatusList.test.tsx
cd WT && bun test src/components/client-lane/agency/RequestLinkRow.test.tsx
cd WT && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: the three agency files are green. `KvSharePanel.test.tsx` matches its baseline list.

- [ ] **Step 8: Mutation checks**
  - In `ApprovalRequestsSection`, render `requestTitle(request)` instead of `subjectRequestTitle(…)`. "titles a deck request by its version, not by artboards" must FAIL. Restore.
  - In `ApprovalStatusList`, always render the `<button>` (ignore `onJump` undefined). "draws a plan row as text when there is nowhere to jump" must FAIL. Restore.
  - In `ItemStatusRow`, replace `itemMeta(approval)` with the old `[artboardWho(approval), pins]` join. "shows a deck's pins without a decision as feedback" must FAIL. Restore.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "disables Request approval on a brand-less deck and says why" — delete `{reason && …}`.
- "opens a deck's form and reports the subject type" — hard-code `subject_type: "kv_file"` in the form-opened call.
- "keeps KV's reason when nothing is marked ready" — pass `true` instead of `hasReadyMarks`.
- "opens the deck's pins from its row and reports the subject type" — hard-code `subject_type: "kv_file"` in `trackStatusRowJumped`.

- [ ] **Step 9: Gate + commit**

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
refactor(web): generic approval-requests section and status list

Both take the subject; deck/plan rows read "Request n · v4", show pins
without a decision as feedback, and jump only where the host can go.
KV keeps its copy and behaviour.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 6: `ClientApprovalSlot` — generic, popover or inline; KV mounts swap

**Files:**
- Rename + rewrite: `src/components/client-lane/agency/KvClientApprovalSlot.tsx` → `ClientApprovalSlot.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (import ~234, JSX ~8608), `motion/KvMotionEditor.tsx` (import ~33, JSX ~2683)
- Test: `src/components/client-lane/agency/ClientApprovalSlot.test.tsx` (create)

**Interfaces:**
- Consumes:
  - Task 1 hooks and `ApprovalSubject`;
  - Task 2 `subjectSlotState`, `SubjectSlotState`, `newReadyLabel`;
  - Task 4 `RequestForm`;
  - Task 5 `ApprovalStatusList`;
  - the existing `lastRequestEmails`, `TONE_DOT`, `plural`.
- Produces:

```ts
export interface ClientApprovalSlotProps {
  subject: ApprovalSubject;
  brandId: string | null;
  compact?: boolean;
  surface: ApprovalSurface;
  formOpen: boolean;
  onFormOpenChange: (open: boolean) => void;
  onHoverReadySet?: (items: ApprovalRequestPreviewItem[] | null) => void;
  onJump?: (approval: AgencyRequestApproval) => void;
  onSent?: (created: CreateApprovalRequestResponse) => void;
  inline?: { statusOpen: boolean; onStatusOpenChange: (open: boolean) => void };
}
```

  `keepFormOpenOnPress` is still exported.

- [ ] **Step 1: Rename**

```bash
cd WT && /usr/bin/git mv src/components/client-lane/agency/KvClientApprovalSlot.tsx src/components/client-lane/agency/ClientApprovalSlot.tsx
```

- [ ] **Step 2: Write the failing test**

Create `src/components/client-lane/agency/ClientApprovalSlot.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  agencyRequest,
  deckApproval,
  deckPreviewItem,
  previewItem,
  requestPreview,
} from "@/lib/client-lane/requestFixtures";
import axiosInstance from "@/services/axios";
import type {
  AgencyRequest,
  ApprovalRequestPreview,
} from "@/services/client-lane";

import { ClientApprovalSlot } from "./ClientApprovalSlot";

const body = () => within(document.body);
const DECK = { type: "deck", id: "d1", name: "Ramadan 2027 strategy" } as const;
const KV = { type: "kv_file", id: "f1", name: "Ramadan hero" } as const;

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function stub(preview: ApprovalRequestPreview, list: AgencyRequest[]) {
  vi.spyOn(axiosInstance, "get").mockImplementation((async (url: string) => {
    if (url === "v1/approval-requests/preview") {
      return { data: { data: preview } };
    }
    if (url === "v1/approval-requests") return { data: { data: list } };
    throw new Error(`unexpected GET ${url}`);
  }) as never);
  return vi
    .spyOn(posthog, "capture")
    .mockImplementation(() => undefined as never);
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("ClientApprovalSlot (spec 2026-10-06 §5.2–5.3)", () => {
  it("offers Request approval on a deck with nothing sent", async () => {
    const capture = stub(requestPreview([deckPreviewItem()]), []);
    const onFormOpenChange = vi.fn();
    render(
      <ClientApprovalSlot
        subject={DECK}
        brandId="b1"
        surface="deck"
        formOpen={false}
        onFormOpenChange={onFormOpenChange}
      />,
      { wrapper: Wrapper }
    );
    fireEvent.click(
      await body().findByRole("button", { name: "Request approval" })
    );
    expect(onFormOpenChange).toHaveBeenCalledWith(true);
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_form_opened",
      expect.objectContaining({ subject_type: "deck", source: "top_bar" })
    );
  });

  it("disables the deck button and carries the reason", async () => {
    stub(requestPreview([], { blocked_reason: "no_brand" }), []);
    render(
      <ClientApprovalSlot
        subject={DECK}
        brandId={null}
        surface="deck"
        formOpen={false}
        onFormOpenChange={vi.fn()}
      />,
      { wrapper: Wrapper }
    );
    const button = await body().findByRole("button", {
      name: "Request approval",
    });
    await waitFor(() => expect(button).toBeDisabled());
    expect(
      body().getByText("Link this deck to a brand to request approval")
    ).toBeInTheDocument();
  });

  it("inline mode toggles the status panel instead of opening a popover", async () => {
    stub(requestPreview([]), [
      agencyRequest({
        approvals: [deckApproval()],
        approvers: [
          {
            name: "Dina",
            email: "dina@brand.test",
            user_id: null,
            personal_url: null,
            decided: false,
          },
        ],
      }),
    ]);
    const onStatusOpenChange = vi.fn();
    render(
      <ClientApprovalSlot
        subject={DECK}
        brandId="b1"
        surface="plan"
        formOpen={false}
        onFormOpenChange={vi.fn()}
        inline={{ statusOpen: false, onStatusOpenChange }}
      />,
      { wrapper: Wrapper }
    );
    fireEvent.click(
      await body().findByRole("button", {
        name: "Approval status: Waiting on Dina · 0/1",
      })
    );
    expect(onStatusOpenChange).toHaveBeenCalledWith(true);
    expect(body().queryByRole("list", { name: "Approval requests" })).toBeNull();
  });

  it("keeps KV's Ready for client button", async () => {
    stub(
      requestPreview([
        previewItem(),
        previewItem({ subject_key: "board:g2", version_id: "g2" }),
      ]),
      []
    );
    render(
      <ClientApprovalSlot
        subject={KV}
        brandId="b1"
        surface="canvas"
        formOpen={false}
        onFormOpenChange={vi.fn()}
        onJump={vi.fn()}
      />,
      { wrapper: Wrapper }
    );
    expect(
      await body().findByRole("button", { name: "Ready for client — 2 artboards" })
    ).toBeInTheDocument();
  });
});
```

- [ ] **Step 3: Run it to see it fail**

```bash
cd WT && bun test src/components/client-lane/agency/ClientApprovalSlot.test.tsx
```

Expected: every test FAILS. `ClientApprovalSlot` is not exported yet (the file still exports `KvClientApprovalSlot`).

- [ ] **Step 4: Rewrite the slot**

Replace the body of `ClientApprovalSlot.tsx`. Keep `keepFormOpenOnPress` and `ReadyIconButton` exactly as they are. Imports and component:

```tsx
"use client";

import { CaretDown, PaperPlaneTilt } from "@phosphor-icons/react";
import clsx from "clsx";
import { useId, useRef, useState, type ReactNode } from "react";

import { Button, CountBadge, Popover, Tooltip } from "@/components/frndos/v2";
import {
  trackApprovalRequestFormOpened,
  trackStatusChipOpened,
  type ApprovalSurface,
} from "@/lib/analytics/client-lane-events";
import { lastRequestEmails } from "@/lib/client-lane/canvasApproval";
import { plural } from "@/lib/client-lane/requests";
import { TONE_DOT } from "@/lib/client-lane/statusTone";
import {
  newReadyLabel,
  subjectSlotState,
  type SubjectSlotState,
} from "@/lib/client-lane/subjectRequests";
import {
  useApprovalRequestPreview,
  useApprovalRequests,
  type AgencyRequestApproval,
  type ApprovalRequestPreviewItem,
  type ApprovalSubject,
  type CreateApprovalRequestResponse,
} from "@/services/client-lane";

import { ApprovalStatusList } from "./ApprovalStatusList";
import { RequestForm } from "./RequestForm";
import { useArtboardThumbnailSync } from "./useArtboardThumbnailSync";

// keepFormOpenOnPress — unchanged (keep its doc comment)

export interface ClientApprovalSlotProps {
  subject: ApprovalSubject;
  brandId: string | null;
  /** Narrow top bar: icon + badge, and the chip shows the fraction only. */
  compact?: boolean;
  surface: ApprovalSurface;
  /** The request form — host state, so a tray or a menu can open it. */
  formOpen: boolean;
  onFormOpenChange: (open: boolean) => void;
  /** KV only: hover / focus on a "ready" affordance frames that set. */
  onHoverReadySet?: (items: ApprovalRequestPreviewItem[] | null) => void;
  /** A status row was picked: KV jumps to the artboard, a deck opens its
   *  pins. Absent → rows are static (a plan). */
  onJump?: (approval: AgencyRequestApproval) => void;
  /** A request went out from the slot's own form. */
  onSent?: (created: CreateApprovalRequestResponse) => void;
  /**
   * Inside a Radix modal (the plan view) a popover portalled to <body> sits
   * under the dialog and cannot be clicked, so the host renders the status
   * list and the form inline; the slot then draws only its button / chip.
   */
  inline?: {
    statusOpen: boolean;
    onStatusOpenChange: (open: boolean) => void;
  };
}

/**
 * The top-bar slot for any subject (spec 2026-10-01 §6.1; 2026-10-06 §5.2,
 * §5.3). KV: Ready for client → status chip. Deck / plan: Request approval
 * (disabled with its reason when it cannot be sent) → status chip. The form
 * drops down under the slot; the chip opens every request with its items.
 */
export function ClientApprovalSlot({
  subject,
  brandId,
  compact = false,
  surface,
  formOpen,
  onFormOpenChange,
  onHoverReadySet,
  onJump,
  onSent,
  inline,
}: ClientApprovalSlotProps) {
  const slotRef = useRef<HTMLDivElement | null>(null);
  const reasonId = useId();
  const [popoverOpen, setPopoverOpen] = useState(false);
  const isKv = subject.type === "kv_file";
  const preview = useApprovalRequestPreview(subject.type, subject.id);
  const requests = useApprovalRequests(subject.type, subject.id);
  const list = requests.data ?? [];
  const readyItems = preview.data?.items ?? [];
  // KV only: ready artboards and sent approvals still missing a composite.
  useArtboardThumbnailSync(isKv ? subject.id : null, [
    ...readyItems,
    ...list.flatMap((request) => request.approvals),
  ]);
  const readyTotal = preview.data?.total ?? 0;
  // A deck / plan waits for its preview too: a brand-less deck must never
  // flash an enabled Request button.
  const loaded = requests.isSuccess && (isKv || preview.isSuccess);
  const state: SubjectSlotState = loaded
    ? subjectSlotState(subject.type, list, preview.data)
    : { kind: "hidden" };
  const statusOpen = inline ? inline.statusOpen : popoverOpen;

  const openForm = () => {
    trackApprovalRequestFormOpened({
      subject_type: subject.type,
      source: "top_bar",
      ready_total: readyTotal,
    });
    onHoverReadySet?.(null);
    onFormOpenChange(true);
  };
  const setStatusOpen = (next: boolean) => {
    if (next && state.kind === "status") {
      trackStatusChipOpened({
        subject_type: subject.type,
        surface,
        request_status: state.request.status,
        request_count: list.length,
        ready_total: state.readyTotal,
      });
    }
    if (inline) inline.onStatusOpenChange(next);
    else setPopoverOpen(next);
  };
  const hover = {
    onMouseEnter: () => onHoverReadySet?.(readyItems),
    onMouseLeave: () => onHoverReadySet?.(null),
    onFocus: () => onHoverReadySet?.(readyItems),
    onBlur: () => onHoverReadySet?.(null),
  };
  const readyLabel = `Ready for client — ${plural(readyTotal, "artboard")}`;

  const chip = (props: { onClick?: () => void }): ReactNode =>
    state.kind === "status" ? (
      <Button
        variant="secondary"
        size="small"
        aria-label={`Approval status: ${state.text}`}
        aria-expanded={inline ? statusOpen : undefined}
        onClick={props.onClick}
        leftIcon={
          // `block`: Button wraps icons in a plain span, where an empty
          // inline span has no size and the dot vanished.
          <span
            aria-hidden
            className={clsx("block size-2 rounded-full", TONE_DOT[state.variant])}
          />
        }
        rightIcon={
          <CaretDown
            size={14}
            aria-hidden
            className={clsx(
              "text-text-inverse-subtle transition-transform duration-200 ease-out",
              statusOpen && "rotate-180"
            )}
          />
        }
      >
        {compact ? state.shortText : state.text}
      </Button>
    ) : null;

  return (
    <div ref={slotRef} className="flex items-center gap-2">
      {state.kind === "ready" &&
        (compact ? (
          <ReadyIconButton
            label={readyLabel}
            count={state.readyTotal}
            onClick={openForm}
            hover={hover}
          />
        ) : (
          <Button
            size="small"
            aria-label={readyLabel}
            leftIcon={<PaperPlaneTilt size={16} />}
            rightIcon={<CountBadge count={state.readyTotal} tone="dark" />}
            onClick={openForm}
            {...hover}
          >
            Ready for client
          </Button>
        ))}

      {state.kind === "request" && (
        <>
          <Tooltip
            content={
              state.disabledReason ?? "Send this version to the client to decide"
            }
          >
            {/* A disabled button fires no pointer events — the span carries
                the hover for the tooltip. */}
            <span className="inline-flex">
              <Button
                size="small"
                leftIcon={<PaperPlaneTilt size={16} />}
                disabled={state.disabledReason !== null}
                aria-describedby={state.disabledReason ? reasonId : undefined}
                onClick={openForm}
              >
                Request approval
              </Button>
            </span>
          </Tooltip>
          {state.disabledReason && (
            <span id={reasonId} className="sr-only">
              {state.disabledReason}
            </span>
          )}
        </>
      )}

      {state.kind === "status" && (
        <>
          {inline ? (
            chip({ onClick: () => setStatusOpen(!statusOpen) })
          ) : (
            <Popover open={popoverOpen} onOpenChange={setStatusOpen}>
              <Popover.Trigger asChild>{chip({})}</Popover.Trigger>
              <Popover.Content side="bottom" align="end" className="w-96 p-2">
                <ApprovalStatusList
                  requests={list}
                  subject={subject}
                  surface={surface}
                  onJump={
                    onJump
                      ? (approval) => {
                          setPopoverOpen(false);
                          onJump(approval);
                        }
                      : undefined
                  }
                />
              </Popover.Content>
            </Popover>
          )}
          {state.readyTotal > 0 && (
            <ReadyIconButton
              label={newReadyLabel(subject.type, state.readyTotal)}
              count={state.readyTotal}
              onClick={openForm}
              hover={hover}
            />
          )}
        </>
      )}

      {/* The form drop-down (popover mode only): anchored to the slot, not
          to one trigger, so a tray can open it too. Inline hosts render
          `RequestForm` themselves. */}
      {!inline && (
        <Popover
          open={formOpen}
          onOpenChange={(next, details) => {
            if (!next) {
              const event = details.event as Event | undefined;
              const target =
                details.reason === "focus-out"
                  ? ((event as FocusEvent | undefined)?.relatedTarget ?? null)
                  : (event?.target ?? null);
              if (
                (details.reason === "outside-press" ||
                  details.reason === "focus-out") &&
                keepFormOpenOnPress(target, slotRef.current)
              ) {
                details.cancel();
                return;
              }
            }
            onFormOpenChange(next);
          }}
        >
          <Popover.Content
            anchor={slotRef}
            side="bottom"
            align="end"
            className="w-96 p-4"
          >
            <RequestForm
              subject={subject}
              brandId={brandId}
              initialEmails={lastRequestEmails(list)}
              prefillMessage={isKv}
              onSent={onSent}
              onDone={() => onFormOpenChange(false)}
              onCancel={() => onFormOpenChange(false)}
            />
          </Popover.Content>
        </Popover>
      )}
    </div>
  );
}
```

`Popover.Trigger asChild` receives the chip element exactly as before; `chip({})` returns the same `Button`. Copy the original `onOpenChange` body for the form popover verbatim (it is reproduced above).

- [ ] **Step 5: Swap the KV mounts**

`KvGeneratorLayout.tsx`: import `{ ClientApprovalSlot } from "@/components/client-lane/agency/ClientApprovalSlot"`. The JSX:

```tsx
                  <ClientApprovalSlot
                    subject={{ type: "kv_file", id: liveFileId, name: title }}
                    brandId={brandId}
                    compact={compactTopNav}
                    surface="canvas"
                    formOpen={requestFormOpen}
                    onFormOpenChange={setRequestFormOpen}
                    onHoverReadySet={setReadySetHover}
                    onJump={(approval) => {
                      if (approval.subject_key === null || approval.phase === null) return;
                      jumpToArtboard({
                        subjectKey: approval.subject_key,
                        phase: approval.phase,
                        versionId: approval.version_id,
                      });
                    }}
                  />
```

`KvMotionEditor.tsx`: the same import. The JSX becomes `<ClientApprovalSlot subject={{ type: "kv_file", id: fileId, name: shareFile?.name ?? "Key visual" }} brandId={shareFile?.brand_id ?? null} surface="motion" formOpen={requestFormOpen} onFormOpenChange={setRequestFormOpen} onJump={handleApprovalJump} />`.

```bash
cd WT && /usr/bin/grep -rn "KvClientApprovalSlot" src || echo "clean"
```

Expected: `clean`.

- [ ] **Step 6: Run tests and regressions**

```bash
cd WT && bun test src/components/client-lane/agency/ClientApprovalSlot.test.tsx
cd WT && bun test src/components/client-lane/agency/ApprovalStatusList.test.tsx
cd WT && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: the first two are green. The third matches its baseline list.

- [ ] **Step 7: Mutation checks**
  - Remove `disabled={state.disabledReason !== null}`. "disables the deck button and carries the reason" must FAIL. Restore.
  - Make the status branch always use the `Popover` (ignore `inline`). "inline mode toggles the status panel instead of opening a popover" must FAIL. Restore.
  - Change `const loaded = …` to `requests.isSuccess` only. Re-run "disables the deck button…". Note whether it still passes. If it does, the flash is not observable in jsdom; record that in the track and keep the guard anyway.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "offers Request approval on a deck with nothing sent" — pass `source: "share_dialog"` in `openForm`.
- "keeps KV's Ready for client button" — call `subjectSlotState("deck", …)` for every subject.

- [ ] **Step 8: Gate + commit**

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
refactor(web): generic client approval slot for KV, deck and plan

ClientApprovalSlot takes the subject; a deck or plan with nothing sent
shows Request approval (disabled with its reason); an inline mode serves
hosts inside a modal. KV editors swap imports only.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Phase 5 — deck and plan agency surfaces

### Task 7: Deck — top-bar slot, Share-dialog section, drain

**Files:**
- Create: `src/lib/client-lane/drain.ts`, `src/lib/client-lane/drain.test.ts`
- Modify: `src/app/(canvas)/decks/[deckId]/components/DeckTopBar.tsx` (imports, state, right cluster ~375)
- Modify: `src/app/(canvas)/decks/[deckId]/components/DeckShareLinks.tsx` (imports, hooks, `requesting` branch, the client-lane block ~408–436)

**Interfaces:**
- Consumes:
  - Task 1 `useApprovals` (existing) and `approvalsKey` (existing);
  - Task 4 `RequestForm`;
  - Task 5 `ApprovalRequestsSection`;
  - Task 6 `ClientApprovalSlot`;
  - existing `ApprovalStatusBlock`.
- Produces: `pendingRoundOf(rounds: readonly AgencyApproval[]): AgencyApproval | null`. Task 10 uses it.

- [ ] **Step 1: Write the failing test**

Create `src/lib/client-lane/drain.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import type { AgencyApproval } from "@/services/client-lane";

import { pendingRoundOf } from "./drain";
import { pendingApproval } from "./testFixtures";

const round = (overrides: Partial<AgencyApproval> = {}): AgencyApproval => ({
  ...pendingApproval({ round: 3 }),
  subject_type: "deck",
  subject_id: "d1",
  share_link_id: null,
  approvers: [],
  ...overrides,
});

describe("pendingRoundOf — the P0a drain (spec 2026-10-06 §7.2)", () => {
  it("is the newest round while it waits", () => {
    expect(pendingRoundOf([round()])?.round).toBe(3);
  });

  it("is null once the newest round is closed", () => {
    expect(
      pendingRoundOf([
        round({ id: "ap3", status: "not_relevant" }),
        round({ id: "ap2", round: 2 }),
      ])
    ).toBeNull();
  });

  it("is null with no rounds", () => {
    expect(pendingRoundOf([])).toBeNull();
  });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/lib/client-lane/drain.test.ts
```

Expected: `Cannot find module './drain'` (1 error).

- [ ] **Step 3: Implement `drain.ts`**

```ts
import type { AgencyApproval } from "@/services/client-lane";

/**
 * A deck / plan P0a round still waiting on the client — the drain (spec
 * 2026-10-06 §7.2, E-4). `GET v1/approvals` lists newest first and only the
 * current round can be pending. While it is, the Share dialog keeps the old
 * status block (withdraw, resend, copy); once it closes — decided, withdrawn,
 * or superseded by a new request (§4.4) — the block is gone for good.
 */
export function pendingRoundOf(
  rounds: readonly AgencyApproval[]
): AgencyApproval | null {
  const current = rounds[0];
  return current && current.status === "pending" ? current : null;
}
```

Run Step 2's command and expect green. Mutation: change the body to `rounds.find((r) => r.status === "pending") ?? null`. "is null once the newest round is closed" must FAIL. Restore.

- [ ] **Step 4: Deck top bar**

Load `frndos-ui` first. In `DeckTopBar.tsx`:

```tsx
import { ClientApprovalSlot } from "@/components/client-lane/agency/ClientApprovalSlot";
import { useClientLaneEnabled } from "@/lib/featureFlags";
```

In the component body, next to the other state:

```tsx
  const clientLane = useClientLaneEnabled();
  // The request form drop-down under the slot (spec 2026-10-06 §5.2).
  const [requestFormOpen, setRequestFormOpen] = useState(false);
```

The right cluster's first child, before the pill `div` (the pill holds 28 px items; the slot's small buttons are 32 px, the cluster's height, so the slot sits just left of the pill and therefore left of `PresenceAvatars`):

```tsx
      <div className="pointer-events-auto flex shrink-0 items-center gap-2">
        {/* Client approval (spec 2026-10-06 §5.2) — where KV has it, left of
            the presence avatars. Not gated by hideHostActions: the Brand Book
            host shows it too. A template is never sent. */}
        {clientLane && !deck.isTemplate && (
          <ClientApprovalSlot
            subject={{ type: "deck", id: deckId, name: deck.title }}
            brandId={deck.brandId}
            surface="deck"
            formOpen={requestFormOpen}
            onFormOpenChange={setRequestFormOpen}
            onJump={() => {
              // A row opens the Comments dock on the deck's pins.
              if (!commentsActive) onToggleComments?.();
            }}
          />
        )}
        <div className="flex items-center gap-0.5 rounded-full …">
```

- [ ] **Step 5: Deck Share dialog**

In `DeckShareLinks.tsx`:

- Imports:
  - add `ApprovalRequestsSection` from `@/components/client-lane/agency/ApprovalRequestsSection`;
  - add `RequestForm` from `@/components/client-lane/agency/RequestForm`;
  - add `pendingRoundOf` from `@/lib/client-lane/drain`;
  - add `approvalsKey, useApprovals` from `@/services/client-lane`;
  - remove the `RequestApprovalPanel` import (the new web never opens a P0a round).
- Hooks, next to `links` and before the `!canShare` early return (hooks order):

```tsx
  const rounds = useApprovals("deck", deckId, {
    enabled: clientLane && canShare,
  });
  // A P0a round from before requests still waiting (drain, spec §7.2).
  const drainRound = pendingRoundOf(rounds.data?.data ?? []);
  const subject = { type: "deck" as const, id: deckId, name: deckTitle };
```

- The `requesting` branch:

```tsx
  if (requesting) {
    return (
      <RequestForm
        subject={subject}
        brandId={brandId}
        onCancel={() => setRequesting(false)}
        onDone={() => {
          setRequesting(false);
          // Sending supersedes a pending P0a round (spec §4.4) — re-read it
          // so the drain block goes.
          void queryClient.invalidateQueries({
            queryKey: approvalsKey("deck", deckId),
          });
        }}
      />
    );
  }
```

- The returned tree starts with the section. It replaces the old `clientLane ? (…ApprovalStatusBlock + Request card…) : <SoonCard …/>` block at the bottom: that block keeps only the flag-off `SoonCard` and the "Edit access" `SoonCard`.

```tsx
    <div className="flex flex-col gap-3 font-geist">
      {clientLane && (
        <>
          <ApprovalRequestsSection
            subject={subject}
            open
            onRequest={() => setRequesting(true)}
          />
          {drainRound && (
            // Drain (spec §5.2): the old round's status and the old card stay
            // only while that round waits. The card now opens the request
            // form — the new web never opens a P0a round (§7.2).
            <div className="flex flex-col gap-1.5">
              <ApprovalStatusBlock subjectType="deck" subjectId={deckId} />
              <div className="flex items-center justify-between gap-3 rounded-lg px-2.5 py-2 ring-1 ring-inset ring-white/10">
                <span className="flex min-w-0 flex-col gap-0.5">
                  <span className="text-textXs text-text-inverse">
                    Request approval
                  </span>
                  <span className="text-textXs text-text-inverse-subtle">
                    Freeze this version and send it to the client to decide.
                  </span>
                </span>
                <Button size="small" onClick={() => setRequesting(true)}>
                  Request
                </Button>
              </div>
            </div>
          )}
          <div aria-hidden className="border-t border-white/5" />
        </>
      )}
      {/* existing "Share" header, link list, create form … unchanged here
          (Task 16 converts their classes) */}
      <div className="flex flex-col gap-1.5 pt-0.5">
        {!clientLane && (
          // Planned, visible, not pretending.
          <SoonCard
            title="Comment access"
            body="Clients leave pins on slides — arrives with the client lane."
          />
        )}
        <SoonCard
          title="Edit access"
          body="Invite people outside the workspace to edit."
        />
      </div>
```

- [ ] **Step 6: Verify**

There is no component test for the deck host. `DeckTopBar` and `DeckShareLinks` read the flag, and a module mock of `@/lib/featureFlags` is forbidden. Covered by `drain.test.ts`, by Tasks 5–6 (the components they mount) and by the manual checklist (Task 17, deck lines).

```bash
cd WT && bun test src/lib/client-lane/drain.test.ts
cd WT && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "decks/\[deckId\]/components/(DeckTopBar|DeckShareLinks)|lib/client-lane/drain"
cd WT && npx eslint "src/app/(canvas)/decks/[deckId]/components/DeckTopBar.tsx" "src/app/(canvas)/decks/[deckId]/components/DeckShareLinks.tsx" src/lib/client-lane/drain.ts
cd WT && /usr/bin/grep -n "RequestApprovalPanel\|createApproval" "src/app/(canvas)/decks/[deckId]/components/DeckShareLinks.tsx" || echo "no P0a request path"
```

Expected: green tests, no tsc lines, eslint 0 errors, `no P0a request path`.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "is the newest round while it waits" — return `null` always.
- "is null with no rounds" — return `rounds[0]` without the status check (undefined ≠ null).

- [ ] **Step 7: Commit**

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): deck approval requests in the top bar and Share dialog

Request approval / status chip left of the presence avatars (also on the
Brand Book host); an Approval requests section above view links; the old
round block stays only while a P0a round is pending (drain).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 8: `PlanDecisionsBlock` reads requests

**Files:**
- Create: `src/lib/client-lane/planDecisions.ts`, `src/lib/client-lane/planDecisions.test.ts`
- Modify: `src/components/client-lane/agency/PlanDecisionsBlock.tsx`
- Modify: `src/components/brands/campaign-planner/SavedPlansList.tsx` (new optional prop `clientLane`, passed to the block)

**Interfaces:**
- Consumes: Task 1 `useApprovalRequests("campaign", id, opts)`; Task 2 `subjectRequestTitle`; existing `useApprovals`.
- Produces:
  - `interface PlanDecisionRow { key: string; title: string; message: string | null; status: ApprovalStatus; deferredUntil: string | null; decisions: ApprovalDecision[] }`;
  - `planDecisionRows(requests: AgencyRequest[], rounds: AgencyApproval[]): PlanDecisionRow[]` (requests first in api order, then P0a rounds newest first);
  - `PlanDecisionsBlock({ planId, enabled }: { planId: string; enabled: boolean })`. It no longer reads the flag (`SharePlanDialog.test` / `SavedPlansList.test` register partial mocks of that module path);
  - `SavedPlansListProps.clientLane?: boolean` (default `false`).

**API note (assumed, reconcile with the api plan):** `GET v1/approvals` for `campaign` keeps returning P0a rounds only (`approval_request_id = null`), as it already does for `kv_file`. If the api also returns request rows there, filter them out with `approval_request_id === null` in `planDecisionRows`.

- [ ] **Step 1: Write the failing test**

Create `src/lib/client-lane/planDecisions.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import type { AgencyApproval } from "@/services/client-lane";

import { planDecisionRows } from "./planDecisions";
import { agencyRequest, deckApproval } from "./requestFixtures";
import { pendingApproval } from "./testFixtures";
import type { ApprovalDecision } from "./types";

const DECIDED: ApprovalDecision = {
  id: "d9",
  actor: "Dina",
  outcome: "changes_required",
  note: "Cut TikTok to 20%",
  pins: [],
  decided_at: null,
  advisory: false,
  deferred_until: null,
};

const planApproval = deckApproval({
  label: "Campaign plan",
  round: 2,
  status: "changes_required",
  decisions: [DECIDED],
});

const round1: AgencyApproval = {
  ...pendingApproval({ id: "ap1", round: 1, status: "approved" }),
  subject_type: "campaign",
  subject_id: "p1",
  share_link_id: null,
  approvers: [],
};

describe("planDecisionRows (spec 2026-10-06 §5.3)", () => {
  it("lists a request with its version and the client's decision", () => {
    const rows = planDecisionRows(
      [
        agencyRequest({
          id: "req2",
          number: 2,
          status: "changes_required",
          message: "Budget v2",
          approvals: [planApproval],
        }),
      ],
      []
    );
    expect(rows).toEqual([
      {
        key: "req2",
        title: "Request 2 · v2",
        message: "Budget v2",
        status: "changes_required",
        deferredUntil: null,
        decisions: [DECIDED],
      },
    ]);
  });

  it("puts requests before rounds from before requests", () => {
    const rows = planDecisionRows(
      [agencyRequest({ id: "req2", number: 2, approvals: [planApproval] })],
      [round1]
    );
    expect(rows.map((r) => r.title)).toEqual(["Request 2 · v2", "Round 1"]);
  });

  it("is empty with neither", () => {
    expect(planDecisionRows([], [])).toEqual([]);
  });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/lib/client-lane/planDecisions.test.ts
```

Expected: `Cannot find module './planDecisions'` (1 error).

- [ ] **Step 3: Implement**

Create `src/lib/client-lane/planDecisions.ts`:

```ts
/**
 * The plan "Decisions" block (FR-24, spec 2026-10-06 §5.3): every request on
 * the plan — its one approval's decisions — then the P0a rounds from before
 * requests (drain). Pure; type-only imports from the service.
 */
import type { AgencyApproval, AgencyRequest } from "@/services/client-lane";

import { subjectRequestTitle } from "./subjectRequests";
import type { ApprovalDecision, ApprovalStatus } from "./types";

export interface PlanDecisionRow {
  key: string;
  /** "Request 2 · v2" / "Round 1". */
  title: string;
  message: string | null;
  status: ApprovalStatus;
  deferredUntil: string | null;
  decisions: ApprovalDecision[];
}

export function planDecisionRows(
  requests: AgencyRequest[],
  rounds: AgencyApproval[]
): PlanDecisionRow[] {
  return [
    ...requests.map((r) => ({
      key: r.id,
      title: subjectRequestTitle(r, "campaign"),
      message: r.message,
      status: r.status,
      deferredUntil: r.deferred_until,
      decisions: r.approvals.flatMap((a) => a.decisions),
    })),
    ...rounds.map((a) => ({
      key: a.id,
      title: `Round ${a.round}`,
      message: a.message,
      status: a.status,
      deferredUntil: a.deferred_until,
      decisions: a.decisions,
    })),
  ];
}
```

Rewrite `PlanDecisionsBlock.tsx`. The markup is unchanged; it maps `rows` instead of `rounds`:

```tsx
"use client";

import {
  OUTCOME_LABEL,
  STATUS_LABEL,
  deferralDate,
  shortWhen,
} from "@/lib/client-lane/format";
import { planDecisionRows } from "@/lib/client-lane/planDecisions";
import { useApprovalRequests, useApprovals } from "@/services/client-lane";

/**
 * Read-only "Decisions" block on the plan detail (FR-24): every request on
 * the plan, then any round from before requests, with decisions and notes —
 * a plan has no canvas to pin, so this is where a client's answer lands for
 * the agency. The host passes the flag (spec 2026-10-06 §5.3).
 */
export function PlanDecisionsBlock({
  planId,
  enabled,
}: {
  planId: string;
  enabled: boolean;
}) {
  const approvals = useApprovals("campaign", planId, { enabled });
  const requests = useApprovalRequests("campaign", planId, { enabled });
  const rows = planDecisionRows(requests.data ?? [], approvals.data?.data ?? []);
  if (!enabled || rows.length === 0) return null;

  return (
    <section className="mt-6 flex flex-col gap-3 border-t border-border-default pt-5 font-geist">
      <span className="text-textXsMedium uppercase tracking-wider text-text-inverse-subtlest">
        Decisions
      </span>
      <ol className="flex flex-col gap-2">
        {rows.map((row) => (
          <li
            key={row.key}
            className="rounded-xl border border-border-default bg-surface-overlay px-3 py-2.5"
          >
            <div className="flex items-center justify-between gap-2">
              <span className="text-textSmMedium text-text-inverse-default">
                {row.title}
                {row.message ? (
                  <span className="font-normal text-text-inverse-subtle">
                    {" · "}
                    {row.message}
                  </span>
                ) : null}
              </span>
              <span className="shrink-0 text-textXs text-text-inverse-subtle">
                {STATUS_LABEL[row.status]}
                {row.deferredUntil
                  ? ` · until ${deferralDate(row.deferredUntil)}`
                  : ""}
              </span>
            </div>
            {/* decisions list: copy the existing <ul>/<p> block verbatim,
                reading row.decisions instead of round.decisions */}
          </li>
        ))}
      </ol>
    </section>
  );
}
```

Where the comment sits, paste the existing `round.decisions.length > 0 ? (<ul …>…</ul>) : (<p …>No decision yet.</p>)` expression, renamed to `row.decisions`. The JSX comment itself is not committed. (`tracking-[0.08em]` becomes `tracking-wider`, a token-only line.)

`SavedPlansList.tsx`: add `clientLane?: boolean;` to `SavedPlansListProps` with the doc "Host-read `show-client-lane`; the list never reads flags (its test registers module mocks)". Default it to `false` in the destructuring, and render `<PlanDecisionsBlock planId={viewTarget.id} enabled={clientLane} />`.

- [ ] **Step 4: Run tests**

```bash
cd WT && bun test src/lib/client-lane/planDecisions.test.ts
cd WT && bun test src/components/brands/campaign-planner/SavedPlansList.test.tsx
```

Expected: the first is green. The second matches its baseline list (the block is module-mocked there).

- [ ] **Step 5: Mutation check**

Drop the `...requests.map(…)` spread. "lists a request with its version and the client's decision" must FAIL. Restore.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "puts requests before rounds from before requests" — spread the rounds first.
- "is empty with neither" — emit a row for a request-less, round-less plan (any invented row fails it).

- [ ] **Step 6: Gate + commit**

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): plan decisions block reads approval requests

Requests (with their version) first, then rounds from before requests;
the host passes the client-lane flag.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 9: `PlanViewModal` — the plan's header bar with the slot

**Files:**
- Create: `src/components/brands/campaign-planner/PlanViewModal.tsx`, `src/components/brands/campaign-planner/PlanViewModal.test.tsx`
- Modify: `src/components/brands/campaign-planner/SavedPlansList.tsx` (its "Plan details" `BaseModal` → `PlanViewModal`)

**Code note:** `SavedPlansList` is exported but **mounted nowhere** (`grep -rn SavedPlansList src/app` finds nothing). The plan view users reach today is `CampaignsLifecycleView`'s "Plan details" modal. Task 11 swaps that one. This task builds the shared modal and keeps `SavedPlansList` on it so the two never drift.

**Interfaces:**
- Consumes:
  - Task 4 `RequestForm`;
  - Task 5 `ApprovalStatusList`;
  - Task 6 `ClientApprovalSlot` (inline);
  - Task 8 `PlanDecisionsBlock({ planId, enabled })`;
  - Task 1 `useApprovalRequests`.
- Produces:

```ts
export interface PlanViewModalProps {
  brandId: string;
  /** null = closed. */
  plan: Plan | null;
  onClose: () => void;
  /** Header Share: the modal closes, then the host opens its Share dialog. */
  onShare: (plan: Plan) => void;
  /** Host-read `show-client-lane`; this file never reads flags. */
  clientLane: boolean;
  /** Open with the request form showing (lifecycle "Share for approval"). */
  initialRequestOpen?: boolean;
}
```

- [ ] **Step 1: Write the failing test**

Create `src/components/brands/campaign-planner/PlanViewModal.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { makePlan } from "@/lib/campaigns-lifecycle/testFactories";
import {
  deckPreviewItem,
  requestPreview,
} from "@/lib/client-lane/requestFixtures";
import axiosInstance from "@/services/axios";

import { PlanViewModal } from "./PlanViewModal";

const body = () => within(document.body);
const PLAN = makePlan({ id: "p1", name: "Q4 media plan" });

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function stub() {
  vi.spyOn(axiosInstance, "get").mockImplementation((async (url: string) => {
    if (url === "v1/approval-requests/preview") {
      return {
        data: {
          data: requestPreview([
            deckPreviewItem({ label: "Campaign plan", round: 2 }),
          ]),
        },
      };
    }
    if (url === "v1/approval-requests") return { data: { data: [] } };
    if (url === "v1/approvals") return { data: { data: [], share_url: null } };
    throw new Error(`unexpected GET ${url}`);
  }) as never);
  vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
}

function renderModal(
  props: Partial<React.ComponentProps<typeof PlanViewModal>> = {}
) {
  return render(
    <PlanViewModal
      brandId="b1"
      plan={PLAN}
      onClose={vi.fn()}
      onShare={vi.fn()}
      clientLane
      {...props}
    />,
    { wrapper: Wrapper }
  );
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("PlanViewModal — the plan's header (spec 2026-10-06 §5.3, E-3)", () => {
  it("heads the plan with its title and Request approval", async () => {
    stub();
    renderModal();
    // The header bar's title + PlanReadOnlyView's own h2.
    expect(
      body().getAllByRole("heading", { name: "Q4 media plan" })
    ).toHaveLength(2);
    expect(
      await body().findByRole("button", { name: "Request approval" })
    ).toBeInTheDocument();
  });

  it("opens the request form inline", async () => {
    stub();
    renderModal();
    const request = await body().findByRole("button", {
      name: "Request approval",
    });
    await waitFor(() => expect(request).not.toBeDisabled());
    fireEvent.click(request);
    // Inside the dialog — a popover portalled to <body> would not be.
    const dialog = within(body().getByRole("dialog"));
    expect(
      await dialog.findByRole("button", { name: "Send request" })
    ).toBeInTheDocument();
  });

  it("opens straight on the form from the lifecycle menu", async () => {
    stub();
    renderModal({ initialRequestOpen: true });
    const dialog = within(body().getByRole("dialog"));
    expect(
      await dialog.findByRole("button", { name: "Send request" })
    ).toBeInTheDocument();
  });

  it("closes, then hands Share to the host", () => {
    stub();
    const onClose = vi.fn();
    const onShare = vi.fn();
    renderModal({ onClose, onShare });
    fireEvent.click(body().getByRole("button", { name: "Share" }));
    expect(onClose).toHaveBeenCalled();
    expect(onShare).toHaveBeenCalledWith(PLAN);
  });

  it("shows no approval affordance while the client lane is off", () => {
    stub();
    renderModal({ clientLane: false });
    expect(body().queryByRole("button", { name: "Request approval" })).toBeNull();
  });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/components/brands/campaign-planner/PlanViewModal.test.tsx
```

Expected: `Cannot find module './PlanViewModal'` (1 error). If the file dies on `PlanReadOnlyView` rendering `makePlan`'s minimal plan, add the missing field to the `makePlan({...})` call (take it from `SharePlanDialog.test.tsx`'s `BASE_PLAN`) and record that in the track.

- [ ] **Step 3: Implement**

Load `frndos-ui` first. Create `src/components/brands/campaign-planner/PlanViewModal.tsx`:

```tsx
"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";

import { ApprovalStatusList } from "@/components/client-lane/agency/ApprovalStatusList";
import { ClientApprovalSlot } from "@/components/client-lane/agency/ClientApprovalSlot";
import { PlanDecisionsBlock } from "@/components/client-lane/agency/PlanDecisionsBlock";
import { RequestForm } from "@/components/client-lane/agency/RequestForm";
import BaseModal from "@/components/frndos/BaseModal";
import Button from "@/components/frndos/Button";
import type { Plan } from "@/lib/campaign-planner/types";
import {
  useApprovalRequests,
  type ApprovalSubject,
} from "@/services/client-lane";

import { PlanReadOnlyView } from "./PlanReadOnlyView";

export interface PlanViewModalProps {
  brandId: string;
  /** null = closed. */
  plan: Plan | null;
  onClose: () => void;
  /** Header Share: the modal closes, then the host opens its Share dialog. */
  onShare: (plan: Plan) => void;
  /** Host-read `show-client-lane`; this file never reads flags. */
  clientLane: boolean;
  /** Open with the request form showing (lifecycle "Share for approval"). */
  initialRequestOpen?: boolean;
}

/**
 * The plan view (spec 2026-10-06 §5.3, E-3): a plan has no editor top bar,
 * so its view carries one — title, the client approval slot, Share. The
 * slot runs INLINE: this is a Radix modal, where a popover portalled to
 * <body> sits under the dialog and cannot be clicked. The form and the
 * status list replace / precede the plan body instead.
 */
export function PlanViewModal({
  brandId,
  plan,
  onClose,
  onShare,
  clientLane,
  initialRequestOpen = false,
}: PlanViewModalProps) {
  return (
    <BaseModal
      isOpen={plan !== null}
      onClose={onClose}
      title="Plan details"
      align="left"
      contentClassName="!w-full !max-w-[min(760px,94vw)] max-h-[88vh] overflow-y-auto"
    >
      {plan && (
        <PlanViewBody
          // A different plan starts fresh (form closed unless asked).
          key={plan.id}
          brandId={brandId}
          plan={plan}
          clientLane={clientLane}
          initialRequestOpen={initialRequestOpen}
          onShare={() => {
            onClose();
            onShare(plan);
          }}
        />
      )}
    </BaseModal>
  );
}

function PlanViewBody({
  brandId,
  plan,
  clientLane,
  initialRequestOpen,
  onShare,
}: {
  brandId: string;
  plan: Plan;
  clientLane: boolean;
  initialRequestOpen: boolean;
  onShare: () => void;
}) {
  const [formOpen, setFormOpen] = useState(clientLane && initialRequestOpen);
  const [statusOpen, setStatusOpen] = useState(false);
  const subject: ApprovalSubject = {
    type: "campaign",
    id: plan.id,
    name: plan.name || "Campaign plan",
  };

  return (
    <div className="flex flex-col gap-4 px-4 py-4 md:px-6 md:py-6">
      <header className="flex items-center justify-between gap-3 border-b border-white/5 pb-3">
        <h2 className="min-w-0 truncate font-geist text-textSmMedium text-text-inverse">
          {subject.name}
        </h2>
        <div className="flex shrink-0 items-center gap-2">
          {clientLane && (
            <ClientApprovalSlot
              subject={subject}
              brandId={brandId}
              surface="plan"
              formOpen={formOpen}
              onFormOpenChange={(open) => {
                setFormOpen(open);
                if (open) setStatusOpen(false);
              }}
              inline={{ statusOpen, onStatusOpenChange: setStatusOpen }}
            />
          )}
          <Button variant="secondary" size="small" onClick={onShare}>
            Share
          </Button>
        </div>
      </header>

      {clientLane && (formOpen || statusOpen) && (
        <PlanApprovalPanel
          brandId={brandId}
          subject={subject}
          formOpen={formOpen}
          onCloseForm={() => setFormOpen(false)}
        />
      )}

      {!formOpen && (
        <>
          <PlanReadOnlyView plan={plan} />
          <PlanDecisionsBlock planId={plan.id} enabled={clientLane} />
        </>
      )}
    </div>
  );
}

/**
 * The inline half of the slot. Mounted only under the flag, so a host
 * without a QueryClient (and the flag off) never reaches a query hook.
 */
function PlanApprovalPanel({
  brandId,
  subject,
  formOpen,
  onCloseForm,
}: {
  brandId: string;
  subject: ApprovalSubject;
  formOpen: boolean;
  onCloseForm: () => void;
}) {
  const qc = useQueryClient();
  const requests = useApprovalRequests(subject.type, subject.id);
  // A sent request moves the plan to In review (spec §4.5): re-read the list.
  const refreshPlans = () =>
    void qc.invalidateQueries({
      queryKey: ["campaign-planner", "plans", brandId],
    });

  if (formOpen) {
    return (
      <RequestForm
        subject={subject}
        brandId={brandId}
        onSent={refreshPlans}
        onDone={onCloseForm}
        onCancel={onCloseForm}
      />
    );
  }
  return (
    <div className="rounded-xl border border-white/10 p-2">
      <ApprovalStatusList
        requests={requests.data ?? []}
        subject={subject}
        surface="plan"
      />
    </div>
  );
}
```

v1 `BaseModal` / `Button` are the modal frame, as everywhere in `campaign-planner`. This file imports nothing from `@/components/frndos/v2` directly, so it is not a v1/v2 mix.

`SavedPlansList.tsx`: replace the "Plan details" `BaseModal` block with:

```tsx
      <PlanViewModal
        brandId={brandId}
        plan={viewTarget}
        onClose={() => setViewTarget(null)}
        onShare={onShare}
        clientLane={clientLane}
      />
```

Import `PlanViewModal`. Drop the now-unused `PlanReadOnlyView` / `PlanDecisionsBlock` imports only if nothing else in the file uses them.

- [ ] **Step 4: Run tests and regressions**

```bash
cd WT && bun test src/components/brands/campaign-planner/PlanViewModal.test.tsx
cd WT && bun test src/components/brands/campaign-planner/SavedPlansList.test.tsx
```

Expected: the first is green. The second matches its baseline (its "opens the read-only plan view" test still finds the "Plan details" title).

- [ ] **Step 5: Mutation checks**
  - In `PlanApprovalPanel`, delete the `if (formOpen) return <RequestForm …/>` branch and drop `inline={…}` from the slot, so only the slot's popover form could show. "opens the request form inline" must FAIL: the popover portals to `<body>`, outside the dialog. Restore.
  - Remove the header's `<h2>`. "heads the plan with its title and Request approval" must FAIL (one heading, not two). Restore.
  - Replace `useState(clientLane && initialRequestOpen)` with `useState(false)`. "opens straight on the form from the lifecycle menu" must FAIL. Restore.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "closes, then hands Share to the host" — drop `onClose()` from the Share handler.
- "shows no approval affordance while the client lane is off" — render the slot regardless of `clientLane`.

- [ ] **Step 6: Gate + commit**

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): plan view header with the client approval slot

PlanViewModal: title, the slot (inline — this is a Radix modal) and Share;
the request form and status list open inline above the plan; decisions
read requests. SavedPlansList uses it too.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 10: `SharePlanDialog` — approval-requests section, drain block

**Files:**
- Modify: `src/components/brands/campaign-planner/SharePlanDialog.tsx`
- Test: `src/components/brands/campaign-planner/SharePlanDialog.approval.test.tsx` (create; the existing `SharePlanDialog.test.tsx` is 6.4 KB but registers module mocks — do not add to it)

**Interfaces:**
- Consumes: Task 4 `RequestForm`, Task 5 `ApprovalRequestsSection`, Task 7 `pendingRoundOf`, existing `ApprovalStatusBlock`, `useApprovals`, `approvalsKey`.
- Produces:
  - `export function PlanApprovalSection({ plan, isOpen, onRequest }: { plan: Plan; isOpen: boolean; onRequest: () => void })` (exported for its test);
  - a private `PlanRequestForm({ brandId, plan, onClose })`.

  Both hold the query hooks. `SharePlanDialog` itself calls none, so its existing test (flag mocked off, no QueryClient) keeps passing.

- [ ] **Step 1: Write the failing test**

Create `src/components/brands/campaign-planner/SharePlanDialog.approval.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { makePlan } from "@/lib/campaigns-lifecycle/testFactories";
import { requestPreview } from "@/lib/client-lane/requestFixtures";
import { pendingApproval } from "@/lib/client-lane/testFixtures";
import axiosInstance from "@/services/axios";

import { PlanApprovalSection } from "./SharePlanDialog";

const body = () => within(document.body);
const PLAN = makePlan({ id: "p1", name: "Q4 media plan" });

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function stub(roundStatus: "pending" | "approved") {
  const get = vi
    .spyOn(axiosInstance, "get")
    .mockImplementation((async (url: string) => {
      if (url === "v1/approval-requests/preview") {
        return { data: { data: requestPreview([]) } };
      }
      if (url === "v1/approval-requests") return { data: { data: [] } };
      if (url === "v1/approvals") {
        return {
          data: {
            data: [
              {
                ...pendingApproval({ round: 3, status: roundStatus }),
                subject_type: "campaign",
                subject_id: "p1",
                share_link_id: null,
                approvers: [],
              },
            ],
            share_url: null,
          },
        };
      }
      throw new Error(`unexpected GET ${url}`);
    }) as never);
  vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
  return get;
}

/** Let every resolved query render (react-query settles over ticks). */
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("SharePlanDialog — approval section (spec 2026-10-06 §5.3, §7.2)", () => {
  it("leads with Approval requests", async () => {
    stub("approved");
    render(<PlanApprovalSection plan={PLAN} isOpen onRequest={vi.fn()} />, {
      wrapper: Wrapper,
    });
    expect(await body().findByText("Approval requests")).toBeInTheDocument();
  });

  it("keeps the old round's block while that round waits", async () => {
    stub("pending");
    render(<PlanApprovalSection plan={PLAN} isOpen onRequest={vi.fn()} />, {
      wrapper: Wrapper,
    });
    expect(await body().findByText("Round 3")).toBeInTheDocument();
  });

  it("drops the old round's block once that round is closed", async () => {
    const get = stub("approved");
    render(<PlanApprovalSection plan={PLAN} isOpen onRequest={vi.fn()} />, {
      wrapper: Wrapper,
    });
    await waitFor(() =>
      expect(get).toHaveBeenCalledWith("v1/approvals", expect.anything())
    );
    await body().findByText("No requests yet.");
    await settle();
    await settle();
    expect(body().queryByText("Round 3")).toBeNull();
  });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/components/brands/campaign-planner/SharePlanDialog.approval.test.tsx
```

Expected: every test FAILS: `PlanApprovalSection` is not exported.

- [ ] **Step 3: Implement**

In `SharePlanDialog.tsx`:

- Imports:
  - add `useQueryClient` from `@tanstack/react-query`;
  - add `ApprovalRequestsSection` and `RequestForm` from `@/components/client-lane/agency/…`;
  - add `pendingRoundOf` from `@/lib/client-lane/drain`;
  - add `approvalsKey, useApprovals` from `@/services/client-lane`;
  - remove the `RequestApprovalPanel` import.
- Update the file's top doc: "(0) Approval requests — the client lane (spec 2026-10-06 §5.3)".
- The `requesting` branch:

```tsx
      {requesting ? (
        <div className="px-4 py-5 md:px-6">
          <PlanRequestForm
            brandId={brandId}
            plan={plan}
            onClose={() => setRequesting(false)}
          />
        </div>
      ) : (
```

- Replace the `{clientLane && (<> {/* (0) Request approval … */} … </>)}` block with:

```tsx
          {clientLane && (
            <>
              <PlanApprovalSection
                plan={plan}
                isOpen={isOpen}
                onRequest={() => setRequesting(true)}
              />
              <div className="h-px w-full bg-border-default" />
            </>
          )}
```

- Add below the component:

```tsx
/**
 * (0) Approval requests (spec 2026-10-06 §5.3): the request section, and —
 * only while a round from before requests still waits — that round's status
 * block (drain, §7.2). Holds the query hooks so `SharePlanDialog` itself
 * calls none.
 */
export function PlanApprovalSection({
  plan,
  isOpen,
  onRequest,
}: {
  plan: Plan;
  isOpen: boolean;
  onRequest: () => void;
}) {
  const rounds = useApprovals("campaign", plan.id, { enabled: isOpen });
  const drainRound = pendingRoundOf(rounds.data?.data ?? []);
  return (
    <section className="flex flex-col gap-3">
      <ApprovalRequestsSection
        subject={{
          type: "campaign",
          id: plan.id,
          name: plan.name || "Campaign plan",
        }}
        open={isOpen}
        onRequest={onRequest}
      />
      {drainRound && (
        <ApprovalStatusBlock
          subjectType="campaign"
          subjectId={plan.id}
          enabled={isOpen}
        />
      )}
    </section>
  );
}

/** The inline request form; a sent request moves the plan to In review and
 *  supersedes a waiting round, so both lists are re-read. */
function PlanRequestForm({
  brandId,
  plan,
  onClose,
}: {
  brandId: string;
  plan: Plan;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  return (
    <RequestForm
      subject={{
        type: "campaign",
        id: plan.id,
        name: plan.name || "Campaign plan",
      }}
      brandId={brandId}
      onSent={() => {
        void qc.invalidateQueries({
          queryKey: ["campaign-planner", "plans", brandId],
        });
        void qc.invalidateQueries({ queryKey: approvalsKey("campaign", plan.id) });
      }}
      onDone={onClose}
      onCancel={onClose}
    />
  );
}
```

- [ ] **Step 4: Run tests and regressions**

```bash
cd WT && bun test src/components/brands/campaign-planner/SharePlanDialog.approval.test.tsx
cd WT && bun test src/components/brands/campaign-planner/SharePlanDialog.test.tsx
```

Expected: the new file is green. The existing file matches its baseline (flag mocked off: none of the new code mounts).

- [ ] **Step 5: Mutation check**

Render `ApprovalStatusBlock` unconditionally (drop `drainRound &&`). "drops the old round's block once that round is closed" must FAIL. If it does not fail, the test is vacuous (the round query had not settled). Add one more `await settle()` until the mutation fails, then restore.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "leads with Approval requests" — remove `<ApprovalRequestsSection …/>`.
- "keeps the old round's block while that round waits" — render the block only when `drainRound && false`.

- [ ] **Step 6: Gate + commit**

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): plan Share dialog uses approval requests

The (0) Request approval block becomes the Approval requests section; the
old round's status shows only while that round still waits.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 11: Lifecycle row menu — requests, plan view, flag gate

**Files:**
- Create: `src/lib/campaigns-lifecycle/approvalMenu.ts`, `src/lib/campaigns-lifecycle/approvalMenu.test.ts`
- Modify: `src/components/brands/campaigns-lifecycle/CampaignsLifecycleView.tsx` (imports ~60–70; `shareForApproval` / `copyApprovalLink` ~434–513; `runPrimary` ~524; `overflowFor` approval pushes ~614–646; the "Plan details" `BaseModal` ~1038)
- Modify: `src/lib/campaign-planner/hooks.ts` (`useSetPlanApproval` `onSuccess`)

**Interfaces:**
- Consumes:
  - Task 1 `listApprovalRequests`, `approvalRequestsRoot`, `approvalsKey`;
  - Task 2 `openRequestOf`;
  - Task 3 `trackApprovalRequestFormOpened` (`source: "lifecycle_menu"`, `ready_total: null`) and `trackApprovalLinkShared`;
  - Task 9 `PlanViewModal`.
- Produces:
  - `type ApprovalMenuKey = "share-for-approval" | "copy-approval-link" | "mark-approved" | "request-changes" | "reopen-review"`;
  - `APPROVAL_MENU_LABEL: Record<ApprovalMenuKey, string>`;
  - `approvalMenuKeys({ clientLane, primaryKey, stage, approvalStatus }): ApprovalMenuKey[]`.

- [ ] **Step 1: Write the failing test**

Create `src/lib/campaigns-lifecycle/approvalMenu.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { APPROVAL_MENU_LABEL, approvalMenuKeys } from "./approvalMenu";

describe("approvalMenuKeys (spec 2026-10-06 §5.3)", () => {
  it("offers no approval item while the client lane is off", () => {
    expect(
      approvalMenuKeys({
        clientLane: false,
        primaryKey: "launch",
        stage: "draft",
        approvalStatus: "in_review",
      })
    ).toEqual([]);
  });

  it("offers sharing and Mark approved on a draft that leads with Launch", () => {
    expect(
      approvalMenuKeys({
        clientLane: true,
        primaryKey: "launch",
        stage: "draft",
        approvalStatus: null,
      })
    ).toEqual(["share-for-approval", "mark-approved"]);
  });

  it("offers the link and Request changes while a plan is in review", () => {
    expect(
      approvalMenuKeys({
        clientLane: true,
        primaryKey: "mark-approved",
        stage: "in_review",
        approvalStatus: "in_review",
      })
    ).toEqual(["copy-approval-link", "request-changes"]);
  });

  it("offers Re-open review once approved", () => {
    expect(
      approvalMenuKeys({
        clientLane: true,
        primaryKey: "launch",
        stage: "approved",
        approvalStatus: "approved",
      })
    ).toEqual(["share-for-approval", "reopen-review"]);
  });

  it("keeps the menu's words", () => {
    expect(APPROVAL_MENU_LABEL).toEqual({
      "share-for-approval": "Share for approval",
      "copy-approval-link": "Copy approval link",
      "mark-approved": "Mark approved",
      "request-changes": "Request changes",
      "reopen-review": "Re-open review",
    });
  });
});
```

These expectations restate today's inline conditions in `overflowFor`. Before implementing, confirm each against the current code (lines ~614–646) and fix the test if the code says otherwise. The rule moves; it must not change.

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/lib/campaigns-lifecycle/approvalMenu.test.ts
```

Expected: `Cannot find module './approvalMenu'` (1 error).

- [ ] **Step 3: Implement the rule**

Create `src/lib/campaigns-lifecycle/approvalMenu.ts`:

```ts
/**
 * The lifecycle row menu's approval items (spec 2026-10-06 §5.3). Every one
 * of them is behind `show-client-lane` now; the conditions are the ones the
 * menu always had, moved here so they are testable.
 */
import type { ApprovalStatus } from "@/lib/campaign-planner/types";

import type { PrimaryActionKey } from "./rowModel";
import type { LifecycleStage } from "./types";

export type ApprovalMenuKey =
  | "share-for-approval"
  | "copy-approval-link"
  | "mark-approved"
  | "request-changes"
  | "reopen-review";

export const APPROVAL_MENU_LABEL: Record<ApprovalMenuKey, string> = {
  "share-for-approval": "Share for approval",
  "copy-approval-link": "Copy approval link",
  "mark-approved": "Mark approved",
  "request-changes": "Request changes",
  "reopen-review": "Re-open review",
};

export function approvalMenuKeys(input: {
  clientLane: boolean;
  primaryKey: PrimaryActionKey;
  stage: LifecycleStage;
  approvalStatus: ApprovalStatus | null;
}): ApprovalMenuKey[] {
  if (!input.clientLane) return [];
  const keys: ApprovalMenuKey[] = [];
  if (
    input.primaryKey !== "share-for-approval" &&
    input.stage !== "in_review"
  ) {
    keys.push("share-for-approval");
  }
  if (input.approvalStatus === "in_review") keys.push("copy-approval-link");
  if (
    input.primaryKey !== "mark-approved" &&
    input.approvalStatus !== "approved"
  ) {
    keys.push("mark-approved");
  }
  if (input.approvalStatus === "in_review") keys.push("request-changes");
  if (input.approvalStatus === "approved") keys.push("reopen-review");
  return keys;
}
```

Run Step 2's command and expect green.

- [ ] **Step 4: Rewire the view**

In `CampaignsLifecycleView.tsx`:

- Imports:
  - replace `import { createApproval, listApprovals } from "@/services/client-lane";` with `import { listApprovalRequests } from "@/services/client-lane";`;
  - add `PlanViewModal` from `@/components/brands/campaign-planner/PlanViewModal`;
  - add `useClientLaneEnabled` from `@/lib/featureFlags`;
  - add `APPROVAL_MENU_LABEL, approvalMenuKeys, type ApprovalMenuKey` from `@/lib/campaigns-lifecycle/approvalMenu`;
  - add `openRequestOf` from `@/lib/client-lane/subjectRequests`;
  - add `trackApprovalLinkShared, trackApprovalRequestFormOpened` from `@/lib/analytics/client-lane-events`.
- State, next to `viewTarget`:

```tsx
  const clientLane = useClientLaneEnabled();
  /** The plan view opens with its request form ("Share for approval"). */
  const [viewRequestOpen, setViewRequestOpen] = useState(false);
```

- Delete `shareForApproval`. Replace `copyApprovalLink` and add `openPlanRequest` and `runApprovalMenu`:

```tsx
  /**
   * "Share for approval" (spec 2026-10-06 §5.3): the plan view with its
   * request form open. It no longer opens a round and copies its link.
   */
  const openPlanRequest = (plan: Plan) => {
    trackApprovalRequestFormOpened({
      subject_type: "campaign",
      source: "lifecycle_menu",
      ready_total: null,
    });
    setViewRequestOpen(true);
    setViewTarget(plan);
  };

  /** The newest open request's link — never the read-only view token. */
  const copyApprovalLink = async (plan: Plan) => {
    try {
      const request = openRequestOf(
        await listApprovalRequests("campaign", plan.id)
      );
      if (!request?.share_url) {
        showToast(
          "No open request",
          "Share for approval first — it creates the client's link.",
          "info"
        );
        return;
      }
      trackApprovalLinkShared({
        subject_type: "campaign",
        round: request.number,
        channel: "copy",
        source: "menu",
      });
      try {
        await navigator.clipboard.writeText(request.share_url);
        showToast("Approval link copied", "", "success");
      } catch {
        showToast("Copy the approval link", request.share_url, "success");
      }
    } catch {
      showToast(
        "Couldn't fetch the approval link",
        "Something went wrong. Try again.",
        "error"
      );
    }
  };

  const runApprovalMenu = (key: ApprovalMenuKey, plan: Plan) => {
    switch (key) {
      case "share-for-approval":
        return openPlanRequest(plan);
      case "copy-approval-link":
        return void copyApprovalLink(plan);
      case "mark-approved":
        return changeApproval(plan, "approved");
      case "request-changes":
        return changeApproval(plan, "changes_requested");
      case "reopen-review":
        return changeApproval(plan, "in_review");
    }
  };
```

- In `runPrimary`, the `share-for-approval` case is gated by the flag. Flag off: no client lane, so it is just the plan view. The primary button's label comes from `primaryActionFor` in `CampaignRow` / `CampaignCard` and is unchanged (see the track note in Step 6).

```tsx
      case "share-for-approval":
        if (item.plan) {
          if (clientLane) openPlanRequest(item.plan);
          else setViewTarget(item.plan);
        }
        break;
```

- In `overflowFor`, replace the five approval `push(…)` blocks ("Approval moves that aren't already the primary action" through "Re-open review") with:

```tsx
      // Approval moves (spec 2026-10-06 §5.3) — all behind the client lane.
      for (const key of approvalMenuKeys({
        clientLane,
        primaryKey,
        stage: item.stage,
        approvalStatus: plan.approvalStatus ?? null,
      })) {
        push(key, APPROVAL_MENU_LABEL[key], () => runApprovalMenu(key, plan));
      }
```

- Replace the "Plan details" `BaseModal` with:

```tsx
      <PlanViewModal
        brandId={brandId}
        plan={viewTarget}
        onClose={() => {
          setViewTarget(null);
          setViewRequestOpen(false);
        }}
        onShare={onShare}
        clientLane={clientLane}
        initialRequestOpen={viewRequestOpen}
      />
```

- Every other `setViewTarget(plan)` call (view-plan, open row) leaves `viewRequestOpen` false, because `onClose` resets it.

In `src/lib/campaign-planner/hooks.ts`, inside `useSetPlanApproval`'s `onSuccess`, after the existing invalidation:

```ts
      // A manual status closes an open request's plan approval (spec
      // 2026-10-06 OQ3, api side) — the slot, the decisions block and the
      // client page re-read it.
      qc.invalidateQueries({
        queryKey: approvalRequestsRoot("campaign", plan.id),
      });
      qc.invalidateQueries({ queryKey: approvalsKey("campaign", plan.id) });
```

Then add `import { approvalRequestsRoot, approvalsKey } from "@/services/client-lane";`.

- [ ] **Step 5: Verify**

```bash
cd WT && bun test src/lib/campaigns-lifecycle/approvalMenu.test.ts
cd WT && bun test src/lib/campaigns-lifecycle/rowModel.test.ts
cd WT && /usr/bin/grep -n "createApproval\|listApprovals\b" src/components/brands/campaigns-lifecycle/CampaignsLifecycleView.tsx || echo "no P0a calls"
cd WT && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "campaigns-lifecycle|campaign-planner/hooks"
cd WT && npx eslint src/components/brands/campaigns-lifecycle/CampaignsLifecycleView.tsx src/lib/campaigns-lifecycle/approvalMenu.ts src/lib/campaign-planner/hooks.ts
```

Expected: green tests, `rowModel` matches its baseline, `no P0a calls`, no new tsc lines, eslint 0 errors.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "offers sharing and Mark approved on a draft that leads with Launch" — drop the `share-for-approval` push.
- "offers the link and Request changes while a plan is in review" — push `request-changes` before `copy-approval-link`.
- "offers Re-open review once approved" — drop the `reopen-review` push.
- "keeps the menu's words" — change one label.

- [ ] **Step 6: Mutation check, track note, commit**

Mutation: delete `if (!input.clientLane) return [];`. "offers no approval item while the client lane is off" must FAIL. Restore.

Track session-log line: "The lifecycle PRIMARY action (`primaryActionFor` in `CampaignRow`/`CampaignCard`) is not flag-gated. With the flag off, a 'Share for approval' primary opens the plan view without a form, and 'Mark approved' stays (a pre-lane agency status). Spec §5.3 gates the menu only."

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): lifecycle menu shares plans through approval requests

Share for approval opens the plan view with the request form; Copy
approval link copies the open request's link; every approval item is
behind show-client-lane; a manual status re-reads the plan's requests.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Phase 6 — the client page serves deck and plan requests

### Task 12: `requestOf` for three types + client-page rules

**Files:**
- Modify: `src/lib/client-lane/requests.ts` (`requestOf`)
- Create: `src/lib/client-lane/requestDecision.ts`, `src/lib/client-lane/requestDecision.test.ts`
- Modify: `src/lib/client-lane/testFixtures.ts` (`publicRequest`, `deckRequestLink`, `planRequestLink`, `kvRequestLink`)
- Modify: `src/components/client-lane/kv/requestItems.ts` (use the shared `viewerOutcome`; `requestProgress` / `approveAllPlan` / `nextUndecided` accept `RequestEntry`)
- Modify: `src/components/client-lane/kv/KvRequestHero.tsx` (`ArtboardIntent` from lib, re-exported)

**Interfaces:**
- Consumes: existing `artboardStateOf`, `stateOfOutcome`, `deferralDate`, `TYPE_LABEL`, `plural`, `RequestDecisionDraft` (`storage.ts`).
- Produces (Tasks 13–15 use these exact names):
  - `type ArtboardIntent = "approve" | "new_version"`;
  - `interface RequestEntry { id: string; versionId: string; round: number; status: ApprovalStatus; replaced: boolean; decisions: ApprovalDecision[]; state: ArtboardState; decidable: boolean; caption: string }`;
  - `viewerOutcome(decisions, viewerName)`;
  - `subjectRequestEntries(type: "deck" | "campaign", view: RequestView, viewerName: string | null): RequestEntry[]`;
  - `approveButtonLabel(type: ShareSubjectType): string`, `changesButtonLabel(pinCount: number): string`;
  - `type DecisionStep = { kind: "post"; draft: RequestDecisionDraft } | { kind: "note" }` and `decisionStep(entryId, intent, ownPins): DecisionStep`;
  - `requestHeadline(type, view, liveItems): string`;
  - `canDownloadRecord(request: PublicRequest): boolean`;
  - `type RequestHeroKind = "kv" | "deck" | "plan" | "text"`, `requestHeroKind(data: ShareLinkData): RequestHeroKind`;
  - `textCardMeta(data: ShareLinkData, round: number | null): string`;
  - fixtures `publicRequest(o?)`, `deckRequestLink(o?)`, `planRequestLink(o?)`, `kvRequestLink(o?)`.

- [ ] **Step 1: Add the fixtures**

Append to `src/lib/client-lane/testFixtures.ts`. Extend the type import with `PublicRequest`, `PublicRequestApproval`, `ShareLinkCampaign`, `ShareLinkDeck`; add `import type { PublicPlan } from "@/lib/campaign-planner/types";` and `import type { DeckDocument } from "@/types/decks";`.

```ts
/** A request as its own link shows it (C-1 `request`), open by default. */
export function publicRequest(
  overrides: Partial<PublicRequest> = {}
): PublicRequest {
  return {
    id: "req1",
    number: 2,
    status: "pending",
    message: null,
    decide_by: null,
    deferred_until: null,
    deferred_note: null,
    approvers: [],
    counts: {
      approved: 0,
      approved_with_changes: 0,
      changes_required: 0,
      pending: 1,
      superseded: 0,
    },
    ...overrides,
  };
}

const DECK_APPROVAL: PublicRequestApproval = {
  id: "apr_d",
  phase: null,
  label: "Deck",
  round: 3,
  version_id: "dv3",
  status: "pending",
  snapshot: null,
  replaced: false,
  decisions: [],
};

/** A deck request link (spec 2026-10-06 §4.9): one approval, v3, no theme. */
export function deckRequestLink(
  overrides: Partial<ShareLinkDeck> = {}
): ShareLinkDeck {
  return {
    type: "deck",
    brand: { name: "Garuda", slug: "garuda", logo_url: null },
    workspace: { name: "Alva" },
    subject: { id: "d1", title: "Ramadan 2027 strategy", thumbnail_url: null },
    version: {
      type: "approval_request",
      id: "req1",
      label: "Request 2",
      created_at: null,
    },
    items: [],
    request: publicRequest(),
    approvals: [DECK_APPROVAL],
    approval: null,
    document: { slides: [{ id: "s1" }, { id: "s2" }] } as unknown as DeckDocument,
    deck: { theme: null, slide_themes: null, play_settings: null },
    access: {
      role: "comment",
      expires_at: null,
      can_decide: true,
      verification_required: false,
    },
    viewer: { kind: "client", name: "Dina", email: "dina@brand.test" },
    ...overrides,
  };
}

/** A campaign-plan request link: one approval, v2. */
export function planRequestLink(
  overrides: Partial<ShareLinkCampaign> = {}
): ShareLinkCampaign {
  return {
    type: "campaign",
    brand: { name: "Garuda", slug: "garuda", logo_url: null },
    workspace: { name: "Alva" },
    subject: { id: "p1", title: "Q4 media plan", thumbnail_url: null },
    version: {
      type: "approval_request",
      id: "req1",
      label: "Request 2",
      created_at: null,
    },
    items: [],
    request: publicRequest(),
    approvals: [
      {
        ...DECK_APPROVAL,
        id: "apr_p",
        label: "Campaign plan",
        round: 2,
        version_id: "fp2",
      },
    ],
    approval: null,
    document: { id: "p1", name: "Q4 media plan" } as unknown as PublicPlan,
    access: {
      role: "comment",
      expires_at: null,
      can_decide: true,
      verification_required: false,
    },
    viewer: { kind: "client", name: "Dina", email: "dina@brand.test" },
    ...overrides,
  };
}

/** A one-artboard KV request link (the Hero board, round 1). */
export function kvRequestLink(overrides: Partial<ShareLinkKv> = {}): ShareLinkKv {
  return kvRound({
    version: {
      type: "approval_request",
      id: "req1",
      label: "Request 1",
      created_at: null,
    },
    items: [],
    approval: null,
    request: publicRequest({ number: 1 }),
    approvals: [
      {
        id: "apr1",
        phase: "craft",
        label: "Hero board",
        round: 1,
        version_id: "g1",
        status: "pending",
        snapshot: HERO,
        replaced: false,
        decisions: [],
      },
    ],
    ...overrides,
  });
}
```

- [ ] **Step 2: Write the failing test**

Create `src/lib/client-lane/requestDecision.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import type { PublicPlan } from "@/lib/campaign-planner/types";
import type { DeckThemeWire } from "@/lib/deck/mapDeckTheme";
import type { DeckDocument } from "@/types/decks";

import { deferralDate } from "./format";
import {
  approveButtonLabel,
  canDownloadRecord,
  changesButtonLabel,
  decisionStep,
  requestHeadline,
  requestHeroKind,
  subjectRequestEntries,
  textCardMeta,
} from "./requestDecision";
import { requestOf } from "./requests";
import {
  deckRequestLink,
  kvRound,
  planRequestLink,
  publicRequest,
} from "./testFixtures";

const THEME = {} as DeckThemeWire;
const DECK = deckRequestLink().approvals![0];

describe("requestOf — every subject (spec 2026-10-06 §6.1)", () => {
  it("reads a deck request link", () => {
    expect(requestOf(deckRequestLink())?.approvals.map((a) => a.id)).toEqual([
      "apr_d",
    ]);
  });

  it("reads a plan request link", () => {
    expect(requestOf(planRequestLink())?.request.number).toBe(2);
  });

  it("leaves P0a round links on the round branch", () => {
    expect(
      requestOf(deckRequestLink({ request: null, approvals: undefined }))
    ).toBeNull();
    expect(requestOf(kvRound())).toBeNull();
  });
});

describe("subjectRequestEntries", () => {
  it("makes a deck request one decidable entry", () => {
    expect(
      subjectRequestEntries("deck", requestOf(deckRequestLink())!, "Dina")
    ).toEqual([
      {
        id: "apr_d",
        versionId: "dv3",
        round: 3,
        status: "pending",
        replaced: false,
        decisions: [],
        state: "undecided",
        decidable: true,
        caption: "Deck · v3",
      },
    ]);
  });

  it("shows this viewer's own answer while the request waits on others", () => {
    const link = deckRequestLink({
      approvals: [
        {
          ...DECK,
          decisions: [
            {
              id: "d1",
              actor: "Dina",
              outcome: "approved_with_changes",
              note: null,
              pins: ["p1"],
              decided_at: "2026-10-06T08:00:00.000Z",
              advisory: true,
              deferred_until: null,
            },
          ],
        },
      ],
    });
    expect(
      subjectRequestEntries("deck", requestOf(link)!, "Dina")[0].state
    ).toBe("approved_with_fixes");
  });
});

describe("one pins/decision rule for every subject (spec §6.3)", () => {
  it("names the approve button per subject", () => {
    expect(approveButtonLabel("deck")).toBe("Approve deck");
    expect(approveButtonLabel("campaign")).toBe("Approve plan");
    expect(approveButtonLabel("kv_file")).toBe("Approve");
  });

  it("names the second button by this visit's pins", () => {
    expect(changesButtonLabel(0)).toBe("Request changes");
    expect(changesButtonLabel(1)).toBe("Send 1 pin as changes");
    expect(changesButtonLabel(3)).toBe("Send 3 pins as changes");
  });

  it("approves with this visit's pins — the api stores approved_with_changes", () => {
    expect(decisionStep("apr_d", "approve", ["p1"])).toEqual({
      kind: "post",
      draft: { approval_ids: ["apr_d"], outcome: "approved", pins: ["p1"] },
    });
  });

  it("sends pins as changes without a note", () => {
    expect(decisionStep("apr_d", "new_version", ["p1", "p2"])).toEqual({
      kind: "post",
      draft: {
        approval_ids: ["apr_d"],
        outcome: "changes_required",
        pins: ["p1", "p2"],
      },
    });
  });

  it("asks for a note before Request changes with no pins", () => {
    expect(decisionStep("apr_d", "new_version", [])).toEqual({ kind: "note" });
  });
});

describe("page copy and record", () => {
  it("heads a deck request with version, request and deadline", () => {
    const view = requestOf(
      deckRequestLink({ request: publicRequest({ decide_by: "2026-10-08" }) })
    )!;
    expect(requestHeadline("deck", view, 1)).toBe(
      `v3 · Request 2 · Decide by ${deferralDate("2026-10-08")}`
    );
  });

  it("keeps KV's headline", () => {
    expect(requestHeadline("kv_file", requestOf(deckRequestLink())!, 3)).toBe(
      "Request 2 · 3 artboards"
    );
  });

  it("offers the record only once every item is decided", () => {
    expect(canDownloadRecord(publicRequest())).toBe(false);
    expect(canDownloadRecord(publicRequest({ status: "approved" }))).toBe(true);
    expect(
      canDownloadRecord(publicRequest({ status: "changes_required" }))
    ).toBe(true);
    expect(canDownloadRecord(publicRequest({ status: "not_relevant" }))).toBe(
      false
    );
  });
});

describe("requestHeroKind / textCardMeta (spec §6.2)", () => {
  it("draws a themed deck with slides as the deck", () => {
    expect(
      requestHeroKind(
        deckRequestLink({
          deck: { theme: THEME, slide_themes: null, play_settings: null },
        })
      )
    ).toBe("deck");
  });

  it("falls back to the text card for a deck without a theme or slides", () => {
    expect(requestHeroKind(deckRequestLink())).toBe("text");
    expect(
      requestHeroKind(
        deckRequestLink({
          deck: { theme: THEME, slide_themes: null, play_settings: null },
          document: { slides: [] } as unknown as DeckDocument,
        })
      )
    ).toBe("text");
  });

  it("draws a plan, or the text card without its projection", () => {
    expect(requestHeroKind(planRequestLink())).toBe("plan");
    expect(
      requestHeroKind(planRequestLink({ document: null as unknown as PublicPlan }))
    ).toBe("text");
    expect(requestHeroKind(kvRound())).toBe("kv");
  });

  it("says type, version and slide count on the text card", () => {
    expect(textCardMeta(deckRequestLink(), 3)).toBe("Deck · v3 · 2 slides");
    expect(textCardMeta(planRequestLink(), 2)).toBe("Campaign plan · v2");
  });
});
```

- [ ] **Step 3: Run it to see it fail**

```bash
cd WT && bun test src/lib/client-lane/requestDecision.test.ts
```

Expected: `Cannot find module './requestDecision'` (1 error).

- [ ] **Step 4: Implement**

`src/lib/client-lane/requests.ts`, `requestOf`:

```ts
/**
 * The request a link was sent for, or `null` — view links, P0a round links
 * (deck, plan, legacy KV) and an api that predates requests. Every subject
 * type (spec 2026-10-06 §6.1; the KV-only gate of 2026-10-01 D-2 is gone).
 */
export function requestOf(data: ShareLinkData): RequestView | null {
  if (!data.request) return null;
  return {
    request: data.request,
    approvals: Array.isArray(data.approvals) ? data.approvals : [],
  };
}
```

Create `src/lib/client-lane/requestDecision.ts`:

```ts
/**
 * The client page's request rules for every subject (spec 2026-10-06 §6):
 * one entry per approval, one pins/decision rule, the header line, which
 * hero draws, and when the approval record can be downloaded. Pure.
 */
import { TYPE_LABEL, deferralDate } from "./format";
import type { RequestView } from "./requests";
import { plural } from "./requests";
import { artboardStateOf, stateOfOutcome, type ArtboardState } from "./statusTone";
import type { RequestDecisionDraft } from "./storage";
import type {
  ApprovalDecision,
  ApprovalStatus,
  DecisionOutcome,
  PublicRequest,
  ShareLinkData,
  ShareSubjectType,
} from "./types";

/** ✓ approve, or the second button (request changes / send pins). */
export type ArtboardIntent = "approve" | "new_version";

/** One decidable item on a request link — a KV artboard is a superset. */
export interface RequestEntry {
  id: string;
  /** What this item's pins anchor on. */
  versionId: string;
  round: number;
  status: ApprovalStatus;
  replaced: boolean;
  decisions: ApprovalDecision[];
  /** The settled verdict, else this viewer's own answer. */
  state: ArtboardState;
  /** Pending and not replaced. */
  decidable: boolean;
  /** "Deck · v3", "Craft · Hero board". */
  caption: string;
}

/**
 * The viewer's own latest answer, matched by the name they decide under —
 * the public shape has no ids. A deferral is request-level, never an item
 * answer.
 */
export function viewerOutcome(
  decisions: ApprovalDecision[],
  viewerName: string | null
): DecisionOutcome | null {
  if (!viewerName) return null;
  const mine = decisions
    .filter((d) => d.actor === viewerName && d.outcome !== "deferred")
    .sort((a, b) => (a.decided_at ?? "").localeCompare(b.decided_at ?? ""));
  return mine[mine.length - 1]?.outcome ?? null;
}

/** A deck / plan request's entries (one in practice — spec §6.2). */
export function subjectRequestEntries(
  type: "deck" | "campaign",
  view: RequestView,
  viewerName: string | null
): RequestEntry[] {
  return view.approvals.map((approval) => {
    const settled = artboardStateOf(approval.status, approval.replaced);
    const mine =
      settled === "undecided"
        ? viewerOutcome(approval.decisions, viewerName)
        : null;
    return {
      id: approval.id,
      versionId: approval.version_id,
      round: approval.round,
      status: approval.status,
      replaced: approval.replaced,
      decisions: approval.decisions,
      state: (mine && stateOfOutcome(mine)) || settled,
      decidable: approval.status === "pending" && !approval.replaced,
      caption: `${TYPE_LABEL[type]} · v${approval.round}`,
    };
  });
}

export function approveButtonLabel(type: ShareSubjectType): string {
  if (type === "deck") return "Approve deck";
  if (type === "campaign") return "Approve plan";
  return "Approve";
}

/** "Request changes" with no pins; "Send N pins as changes" with N. */
export function changesButtonLabel(pinCount: number): string {
  return pinCount > 0
    ? `Send ${plural(pinCount, "pin")} as changes`
    : "Request changes";
}

export type DecisionStep =
  | { kind: "post"; draft: RequestDecisionDraft }
  | { kind: "note" };

/**
 * Pins are separate from the decision (spec §6.3). Approve carries this
 * visit's pins (the api stores it as `approved_with_changes`); the second
 * button posts `changes_required` with the pins, or — with none — asks for
 * the required note first.
 */
export function decisionStep(
  entryId: string,
  intent: ArtboardIntent,
  ownPins: readonly string[]
): DecisionStep {
  if (intent === "approve" || ownPins.length > 0) {
    return {
      kind: "post",
      draft: {
        approval_ids: [entryId],
        outcome: intent === "approve" ? "approved" : "changes_required",
        pins: [...ownPins],
      },
    };
  }
  return { kind: "note" };
}

/** The h1's tail: KV "Request 2 · 8 artboards"; a deck / plan
 *  "v3 · Request 2 · Decide by Thu 8 Oct" (journey board 5). */
export function requestHeadline(
  type: ShareSubjectType,
  view: RequestView,
  liveItems: number
): string {
  if (type === "kv_file") {
    return `Request ${view.request.number} · ${plural(liveItems, "artboard")}`;
  }
  const round = view.approvals[0]?.round;
  return [
    round ? `v${round}` : null,
    `Request ${view.request.number}`,
    view.request.decide_by
      ? `Decide by ${deferralDate(view.request.decide_by)}`
      : null,
  ]
    .filter(Boolean)
    .join(" · ");
}

/** The client may download the record once every item is decided (§6.5);
 *  the api 404s before that, and a withdrawn request is not "decided". */
export function canDownloadRecord(request: PublicRequest): boolean {
  return request.status !== "pending" && request.status !== "not_relevant";
}

export type RequestHeroKind = "kv" | "deck" | "plan" | "text";

/** What draws a request link (spec §6.2): no theme or no slides on a deck,
 *  or no plan projection, is the text card — never "no style to render". */
export function requestHeroKind(data: ShareLinkData): RequestHeroKind {
  if (data.type === "kv_file") return "kv";
  if (data.type === "deck") {
    return data.deck?.theme && (data.document?.slides?.length ?? 0) > 0
      ? "deck"
      : "text";
  }
  return data.document ? "plan" : "text";
}

/** "Deck · v3 · 12 slides" / "Campaign plan · v2". */
export function textCardMeta(data: ShareLinkData, round: number | null): string {
  const parts: string[] = [TYPE_LABEL[data.type]];
  if (round) parts.push(`v${round}`);
  if (data.type === "deck") {
    const slides = data.document?.slides?.length ?? 0;
    if (slides > 0) parts.push(plural(slides, "slide"));
  }
  return parts.join(" · ");
}
```

`src/components/client-lane/kv/requestItems.ts`:
- delete the local `viewerOutcome`, and import `viewerOutcome` and `type RequestEntry` from `@/lib/client-lane/requestDecision`;
- `requestProgress(artboards: RequestEntry[])`;
- `approveAllPlan(artboards: RequestEntry[], pinnedVersions)`;
- `nextUndecided<T extends RequestEntry>(artboards: T[], currentId: string | null): T | null`.

`RequestArtboard` keeps its fields and is structurally a `RequestEntry`. Leave it as is.

`src/components/client-lane/kv/KvRequestHero.tsx`: replace `export type ArtboardIntent = "approve" | "new_version";` with:

```ts
import type { ArtboardIntent } from "@/lib/client-lane/requestDecision";
export type { ArtboardIntent };
```

- [ ] **Step 5: Run tests and regressions**

```bash
cd WT && bun test src/lib/client-lane/requestDecision.test.ts
cd WT && bun test src/lib/client-lane/round.test.ts
cd WT && bun test src/components/client-lane/kv/KvRequestHero.test.tsx
cd WT && bun test src/components/client-lane/DecisionPage.test.tsx
```

Expected: the first is green; the rest match their baselines. `requestOf` now also accepts deck/plan, so from here until Task 15 a deck/plan request link takes the page's request branch with no entries yet: the "no style" box and an empty rail. No existing suite renders that shape, and nothing ships before Task 15.

- [ ] **Step 6: Mutation checks**
  - In `requestOf`, put back `data.type !== "kv_file" ||`. "reads a deck request link" must FAIL. Restore.
  - In `decisionStep`, post `pins: []` on approve. "approves with this visit's pins…" must FAIL. Restore.
  - In `requestHeroKind`, drop the slide-count condition. "falls back to the text card for a deck without a theme or slides" must FAIL. Restore.
  - In `canDownloadRecord`, return `request.status !== "pending"`. "offers the record only once every item is decided" must FAIL. Restore.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "reads a plan request link" — make `requestOf` return null unless `data.type === "deck"`.
- "leaves P0a round links on the round branch" — drop `if (!data.request) return null;`.
- "makes a deck request one decidable entry" — write `caption: "Deck"`.
- "shows this viewer's own answer while the request waits on others" — use `settled` only.
- "names the approve button per subject" — return "Approve" always.
- "names the second button by this visit's pins" — write `plural(pinCount, "pins")` ("Send 1 pins…").
- "sends pins as changes without a note" — post `outcome: "approved"` for both intents.
- "asks for a note before Request changes with no pins" — post even with no pins.
- "heads a deck request with version, request and deadline" — drop the `Decide by` part.
- "keeps KV's headline" — use the deck line for KV.
- "draws a themed deck with slides as the deck" — return `"text"` for every deck.
- "draws a plan, or the text card without its projection" — return `"plan"` regardless of `document`.
- "says type, version and slide count on the text card" — drop the slide count.

- [ ] **Step 7: Gate + commit**

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): request-link rules for deck and plan

requestOf accepts every subject; one entry model, one pins/decision rule
("Request changes" / "Send N pins as changes"), the deck/plan headline,
the hero choice with a text-only fallback, and when the record downloads.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 13: Title, description and OG for deck/plan request links

**Files:**
- Modify: `src/lib/client-lane/round.ts` (`shareImageAlt`; new `shareDescription`)
- Modify: `src/app/s/[token]/page.tsx` (description)
- Test: `src/lib/client-lane/round.test.ts` (append; 3.8 KB today)

**Interfaces:**
- Consumes: Task 12 fixtures and `requestOf`.
- Produces: `shareDescription(data: ShareLinkData): string`. `shareImageAlt` / `shareTitle` return "Approve: {title} ({deck | campaign plan}, v{round})" for an open deck/plan request link and drop "Approve: " once it is settled. KV strings are unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `src/lib/client-lane/round.test.ts`. Add `ogPill`, `shareDescription` to the `./round` import and `deckRequestLink`, `planRequestLink`, `publicRequest` to the fixtures import:

```ts
describe("deck / plan request links (spec 2026-10-06 §6.5)", () => {
  it("titles an open deck request as a call to approve", () => {
    expect(shareImageAlt(deckRequestLink())).toBe(
      "Approve: Ramadan 2027 strategy (deck, v3)"
    );
    expect(shareTitle(deckRequestLink())).toBe(
      "For Dina · Approve: Ramadan 2027 strategy (deck, v3) — Garuda via Alva"
    );
  });

  it("titles a plan request the same way", () => {
    expect(shareImageAlt(planRequestLink())).toBe(
      "Approve: Q4 media plan (campaign plan, v2)"
    );
  });

  it("drops the call to approve once the request is settled", () => {
    expect(
      shareImageAlt(
        deckRequestLink({ request: publicRequest({ status: "approved" }) })
      )
    ).toBe("Ramadan 2027 strategy (deck, v3)");
  });

  it("asks for a decision on the OG pill and falls back to the text card", () => {
    expect(ogPill(deckRequestLink())).toBe("Needs your decision");
    expect(ogThumbnailUrl(deckRequestLink())).toBeNull();
  });

  it("describes a deck request with its message", () => {
    expect(
      shareDescription(
        deckRequestLink({ request: publicRequest({ message: "  Final cut  " }) })
      )
    ).toBe("Final cut");
    expect(shareDescription(deckRequestLink())).toBe("Needs your decision");
  });
});
```

- [ ] **Step 2: Run them to see them fail**

```bash
cd WT && bun test src/lib/client-lane/round.test.ts
```

Expected: the three title tests FAIL (today: "Ramadan 2027 strategy · Request 2 · 1 artboard"). `shareDescription` is not a function. The OG pill test already passes; it pins the behaviour.

- [ ] **Step 3: Implement**

In `round.ts`, at the top of `shareImageAlt`:

```ts
export function shareImageAlt(data: ShareLinkData): string {
  const view = requestOf(data);
  if (view && data.type !== "kv_file") {
    // "Approve: Ramadan 2027 strategy (deck, v3)" (spec 2026-10-06 §6.5).
    const round = view.approvals[0]?.round;
    const what = `${data.type === "deck" ? "deck" : "campaign plan"}${round ? `, v${round}` : ""}`;
    const lead = view.request.status === "pending" ? "Approve: " : "";
    return `${lead}${data.subject.title} (${what})`;
  }
  const artboards = requestArtboardCount(data);
  // …existing body unchanged
```

Append:

```ts
/** `generateMetadata`'s description: the round's or the request's message. */
export function shareDescription(data: ShareLinkData): string {
  return (
    data.approval?.message?.trim() ||
    data.request?.message?.trim() ||
    "Needs your decision"
  );
}
```

`src/app/s/[token]/page.tsx`: import `shareDescription` with the other `round` helpers. Replace the `const description = …` expression with `const description = shareDescription(data);`.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "titles an open deck request as a call to approve" — delete the deck/plan branch.
- "titles a plan request the same way" — hard-code `deck`.
- "drops the call to approve once the request is settled" — always prefix `Approve: `.
- "asks for a decision on the OG pill and falls back to the text card" — make `ogPill` return null for a non-KV request.

- [ ] **Step 4: Run, mutate, commit**

```bash
cd WT && bun test src/lib/client-lane/round.test.ts
```

Expected: all pass, including the earlier KV round/request title tests.

Mutation: in `shareDescription`, write `(data.type === "kv_file" ? data.request?.message?.trim() : "")`. "describes a deck request with its message" must FAIL. Restore.

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): titles and OG text for deck and plan request links

"Approve: Ramadan 2027 strategy (deck, v3)" while open; the request's
message as the description; the existing text card stays the fallback.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 14: Rail, action bar and note sheet — one rule, every subject

**Files:**
- Modify: `src/components/client-lane/RequestRail.tsx` (`FocusedArtboardPanel`, `RequestActionBar`)
- Modify: `src/components/client-lane/sheets/NewVersionNoteSheet.tsx` (retitled button and doc)
- Modify: `src/components/client-lane/DecisionPage.tsx` (pass the two labels: the only change here)
- Test: `src/components/client-lane/RequestRail.test.tsx` (create)

**Interfaces:**
- Consumes: Task 12 `RequestEntry`, `ArtboardIntent`, `approveButtonLabel`, `changesButtonLabel`.
- Produces:
  - `FocusedArtboardPanel({ artboard: RequestEntry; includedPins: number; pinHint?: string | null; children? })`. Undefined `pinHint` keeps the KV hint; `null` hides it (a plan);
  - `RequestActionBar({ focused: RequestEntry | null; plan; approveLabel: string; changesLabel: string; nextId?; busy; onApproveAll; onDecide: (entry: RequestEntry, intent: ArtboardIntent) => void; onNext? })`.

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/RequestRail.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { fireEvent, render, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  changesButtonLabel,
  type RequestEntry,
} from "@/lib/client-lane/requestDecision";

import { FocusedArtboardPanel, RequestActionBar } from "./RequestRail";
import { NewVersionNoteSheet } from "./sheets/NewVersionNoteSheet";

const body = () => within(document.body);
const ENTRY: RequestEntry = {
  id: "apr_d",
  versionId: "dv3",
  round: 3,
  status: "pending",
  replaced: false,
  decisions: [],
  state: "undecided",
  decidable: true,
  caption: "Deck · v3",
};
const NO_ALL = { ids: [], skippedWithPins: 0 };

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("RequestActionBar — one rule (spec 2026-10-06 §6.3)", () => {
  it("labels a deck's buttons and sends pins as changes", () => {
    const onDecide = vi.fn();
    render(
      <RequestActionBar
        focused={ENTRY}
        plan={NO_ALL}
        approveLabel="Approve deck"
        changesLabel={changesButtonLabel(2)}
        busy={false}
        onApproveAll={vi.fn()}
        onDecide={onDecide}
      />
    );
    expect(
      body().getByRole("button", { name: "Approve deck" })
    ).toBeInTheDocument();
    fireEvent.click(
      body().getByRole("button", { name: "Send 2 pins as changes" })
    );
    expect(onDecide).toHaveBeenCalledWith(ENTRY, "new_version");
  });

  it("never says Request new version", () => {
    render(
      <RequestActionBar
        focused={ENTRY}
        plan={NO_ALL}
        approveLabel="Approve"
        changesLabel={changesButtonLabel(0)}
        busy={false}
        onApproveAll={vi.fn()}
        onDecide={vi.fn()}
      />
    );
    expect(
      body().getByRole("button", { name: "Request changes" })
    ).toBeInTheDocument();
    expect(body().queryByText("Request new version")).toBeNull();
  });
});

describe("FocusedArtboardPanel — pin hint", () => {
  it("keeps the pin hint by default", () => {
    render(<FocusedArtboardPanel artboard={ENTRY} includedPins={0} />);
    expect(
      body().getByText(
        "Tap the artwork to pin a note — it rides on your decision."
      )
    ).toBeInTheDocument();
  });

  it("hides it where nothing can be pinned (a plan)", () => {
    render(
      <FocusedArtboardPanel
        artboard={{ ...ENTRY, caption: "Campaign plan · v2" }}
        includedPins={0}
        pinHint={null}
      />
    );
    expect(body().queryByText(/Tap the artwork/)).toBeNull();
  });
});

describe("NewVersionNoteSheet — retitled", () => {
  it("submits as Request changes", () => {
    render(
      <NewVersionNoteSheet
        open
        caption="Deck · v3"
        busy={false}
        onSubmit={vi.fn()}
        onClose={vi.fn()}
      />
    );
    expect(
      body().getByRole("button", { name: "Request changes" })
    ).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/components/client-lane/RequestRail.test.tsx
```

Expected:
- "labels a deck's buttons…" FAILS (the button reads "Approve");
- "never says Request new version" FAILS;
- "hides it where nothing can be pinned" FAILS (no `pinHint` prop yet);
- the note sheet test FAILS ("Ask for a new version").

- [ ] **Step 3: Implement**

`RequestRail.tsx`:
- import `type ArtboardIntent, type RequestEntry` from `@/lib/client-lane/requestDecision`;
- drop the `ArtboardIntent` import from `./kv/KvRequestHero`;
- drop `type RequestArtboard` from the `./kv/requestItems` import (keep `approveAllLabel`, `completionSummary`, `progressLabel`, `ApproveAllPlan`, `RequestProgress`).

```tsx
const PIN_HINT = "Tap the artwork to pin a note — it rides on your decision.";

/** The focused item in the rail: its state, its pin threads, and how many
 *  of this visit's pins ride on the decision. */
export function FocusedArtboardPanel({
  artboard,
  includedPins,
  pinHint = PIN_HINT,
  children,
}: {
  artboard: RequestEntry;
  includedPins: number;
  /** null where nothing can be pinned (a plan). */
  pinHint?: string | null;
  /** Its `PinList`. */
  children?: ReactNode;
}) {
```

The hint paragraph becomes:

```tsx
      {artboard.decidable && (includedPins > 0 || pinHint) && (
        <p className="text-textXs text-text-inverse-subtle">
          {includedPins > 0
            ? `${includedPins} ${includedPins === 1 ? "pin" : "pins"} included`
            : pinHint}
        </p>
      )}
```

`RequestActionBar`:
- props `focused: RequestEntry | null`, plus `approveLabel: string` and `changesLabel: string` (doc: "spec 2026-10-06 §6.3: 'Approve deck' / 'Approve plan' / 'Approve'; 'Request changes' / 'Send N pins as changes'");
- `onDecide: (entry: RequestEntry, intent: ArtboardIntent) => void`;
- the two button labels become `{approveLabel}` and `{changesLabel}`;
- the stacked-buttons comment's "Request new version" becomes "the second button".

`NewVersionNoteSheet.tsx`: the submit button reads `Request changes`. Change the doc's first line to "Request changes on an item with no pins from this visit (spec 2026-10-06 §6.3)".

`DecisionPage.tsx` (compile + KV label change): on `<RequestActionBar …>` add

```tsx
                  approveLabel={approveButtonLabel(data.type)}
                  changesLabel={changesButtonLabel(
                    focusedArtboard ? pinsOn(focusedArtboard).length : 0
                  )}
```

Import `approveButtonLabel` and `changesButtonLabel` from `@/lib/client-lane/requestDecision`.

- [ ] **Step 4: Run tests and regressions**

```bash
cd WT && bun test src/components/client-lane/RequestRail.test.tsx
cd WT && bun test src/components/client-lane/DecisionPage.test.tsx
cd WT && bun test src/components/client-lane/kv/KvRequestHero.test.tsx
```

Expected: the first is green; the others match their baselines.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "never says Request new version" — put back the `Request new version` literal.
- "keeps the pin hint by default" — default `pinHint` to `null`.
- "hides it where nothing can be pinned (a plan)" — ignore `pinHint` (always `PIN_HINT`).
- "submits as Request changes" — put back "Ask for a new version".

- [ ] **Step 5: Mutation check, gate, commit**

Mutation: hard-code `Approve` in the action bar. "labels a deck's buttons and sends pins as changes" must FAIL. Restore.

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): one pins/decision rule on the request rail

Approve deck / Approve plan / Approve; the second button is "Request
changes" with no pins and "Send N pins as changes" with N; KV's "Request
new version" is gone; the note sheet submits as Request changes.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 15: `RequestHero`, text card, record button — `DecisionPage` serves deck and plan requests

**Files:**
- Create: `src/components/client-lane/RequestHero.tsx`, `src/components/client-lane/SubjectTextCard.tsx`
- Modify: `src/lib/client-lane/publicApi.ts` (`downloadPublicRecord`)
- Modify: `src/components/client-lane/DecisionPage.tsx`
- Test: `src/components/client-lane/DecisionPage.request.test.tsx` (create; `DecisionPage.test.tsx` is 22 KB — keep new coverage in this sibling)

**Interfaces:**
- Consumes:
  - Task 12: `RequestEntry`, `ArtboardIntent`, `subjectRequestEntries`, `decisionStep`, `requestHeadline`, `requestHeroKind`, `RequestHeroKind`, `textCardMeta`, `canDownloadRecord`, fixtures;
  - Task 14: labels;
  - Task 3: `saveBlob`, `trackApprovalRecordDownloaded` / `…Failed`;
  - Task 2: `recordFilename`.
- Produces:
  - `RequestHero({ kind, kv?, deck?, plan?, text })` with `DeckHeroProps = ComponentProps<typeof DeckHero>`;
  - `SubjectTextCard({ title, meta })`;
  - `downloadPublicRecord(token, laneCode?): Promise<Blob>`.

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/DecisionPage.request.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { PublicPlan } from "@/lib/campaign-planner/types";
import {
  deckRequestLink,
  kvRequestLink,
  pinComment,
  planRequestLink,
  publicRequest,
} from "@/lib/client-lane/testFixtures";
import type {
  ApprovalDecision,
  PublicComment,
  RequestDecisionResponse,
  ShareLinkData,
} from "@/lib/client-lane/types";
import { axiosPublic } from "@/services/axios";

import { DecisionPage } from "./DecisionPage";

const body = () => within(document.body);
const DECK = deckRequestLink().approvals![0];

const APPROVED: ApprovalDecision = {
  id: "d1",
  actor: "Dina",
  outcome: "approved",
  note: null,
  pins: [],
  decided_at: "2026-10-06T09:00:00.000Z",
  advisory: false,
  deferred_until: null,
};

const SETTLED = {
  approved: 1,
  approved_with_changes: 0,
  changes_required: 0,
  pending: 0,
  superseded: 0,
};

const DECIDED: RequestDecisionResponse = {
  results: [{ approval_id: "apr_d", result: "decided", decision: APPROVED }],
  request: publicRequest({ status: "approved", counts: SETTLED }),
  approvals: [{ ...DECK, status: "approved", decisions: [APPROVED] }],
};

/** The public edge — spied, never vi.mock'ed. `/s/session` hands back a
 *  lane code, so the client viewer posts without a name gate. */
function stubApi(decision: () => unknown = () => DECIDED) {
  vi.spyOn(globalThis, "fetch").mockImplementation(
    (async () =>
      new Response(JSON.stringify({ code: "abcdefghijklmnop" }), {
        status: 200,
      })) as unknown as typeof fetch
  );
  const get = vi.spyOn(axiosPublic, "get").mockImplementation((async (
    url: string
  ) => {
    if (url === "public/share-links/tok/comments") return { data: { data: [] } };
    if (url === "public/share-links/tok/record.pdf") {
      return { data: new Blob(["%PDF"]) };
    }
    throw new Error(`unexpected GET ${url}`);
  }) as never);
  const post = vi.spyOn(axiosPublic, "post").mockImplementation((async (
    url: string,
    input: Record<string, unknown>
  ) => {
    if (url === "public/share-links/tok/comments") {
      const anchor = input.anchor as PublicComment["anchor"];
      return {
        data: {
          data: pinComment("c_new", anchor?.id ?? "", "2026-10-06T09:00:00.000Z", {
            anchor,
            body: String(input.body),
          }),
        },
      };
    }
    if (url === "public/share-links/tok/decision") {
      return { data: { data: decision() } };
    }
    if (url === "public/lane/code") return { data: {} };
    throw new Error(`unexpected POST ${url}`);
  }) as never);
  const capture = vi
    .spyOn(posthog, "capture")
    .mockImplementation(() => undefined as never);
  return { get, post, capture };
}

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function renderPage(data: ShareLinkData) {
  return render(<DecisionPage token="tok" initialData={data} />, {
    wrapper: QueryWrapper,
  });
}

const noteBox = () => body().getByRole("textbox", { name: /Write a comment/ });

/** jsdom lays nothing out — give the pin layer a 200×100 box, then tap it. */
function tapPinLayer(xPx: number, yPx: number) {
  const layer = document.querySelector(
    "[data-client-lane-pin-layer]"
  ) as HTMLElement;
  vi.spyOn(layer, "getBoundingClientRect").mockReturnValue({
    left: 0,
    top: 0,
    width: 200,
    height: 100,
    right: 200,
    bottom: 100,
    x: 0,
    y: 0,
    toJSON: () => ({}),
  } as DOMRect);
  fireEvent.click(layer, { clientX: xPx, clientY: yPx });
}

beforeEach(() => {
  vi.restoreAllMocks();
  window.localStorage.clear();
  window.sessionStorage.clear();
});

describe("DecisionPage — a deck request link (spec 2026-10-06 §6)", () => {
  it("renders a theme-less deck request as the text card and decides it", async () => {
    const { post, capture } = stubApi();
    renderPage(deckRequestLink());

    expect(await body().findByText("Deck · v3 · 2 slides")).toBeInTheDocument();
    expect(
      body().queryByText("This deck has no style to render with.")
    ).toBeNull();
    expect(body().getByRole("heading", { level: 1 })).toHaveTextContent(
      "Ramadan 2027 strategy · v3 · Request 2"
    );
    expect(
      body().getByRole("button", { name: "Request changes" })
    ).toBeInTheDocument();

    fireEvent.click(body().getByRole("button", { name: "Approve deck" }));
    await waitFor(() =>
      expect(post).toHaveBeenCalledWith(
        "public/share-links/tok/decision",
        expect.objectContaining({ approval_ids: ["apr_d"], outcome: "approved" }),
        expect.anything()
      )
    );
    expect(capture).toHaveBeenCalledWith(
      "client_lane.client_artboard_decided",
      expect.objectContaining({ subject_type: "deck" })
    );
    expect(
      await body().findByRole("button", { name: "Download approval record" })
    ).toBeInTheDocument();
  });

  it("asks a deck viewer for a code, never the magic link", async () => {
    stubApi(() => {
      throw { response: { status: 403, data: { code: "verification_required" } } };
    });
    renderPage(deckRequestLink());
    fireEvent.click(await body().findByRole("button", { name: "Approve deck" }));
    expect(await body().findByText("Confirm it's you")).toBeInTheDocument();
    expect(body().queryByText("This one moves budget")).toBeNull();
  });

  it("downloads the approval record once the request is decided", async () => {
    const { get } = stubApi();
    Object.assign(URL, {
      createObjectURL: vi.fn(() => "blob:record"),
      revokeObjectURL: vi.fn(),
    });
    const names: string[] = [];
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(
      function (this: HTMLAnchorElement) {
        names.push(this.download);
      }
    );
    renderPage(
      deckRequestLink({
        request: publicRequest({ status: "approved", counts: SETTLED }),
        approvals: [{ ...DECK, status: "approved", decisions: [APPROVED] }],
      })
    );
    fireEvent.click(
      await body().findByRole("button", { name: "Download approval record" })
    );
    await waitFor(() =>
      expect(names).toEqual([
        "Ramadan 2027 strategy — Request 2 — approval record.pdf",
      ])
    );
    expect(get).toHaveBeenCalledWith(
      "public/share-links/tok/record.pdf",
      expect.objectContaining({ responseType: "blob" })
    );
  });

  it("offers no record on a withdrawn request", async () => {
    stubApi();
    renderPage(
      deckRequestLink({
        request: publicRequest({ status: "not_relevant" }),
        approvals: [{ ...DECK, status: "not_relevant" }],
      })
    );
    expect(
      await body().findByText(
        "This request was withdrawn by the team. Nothing more is needed from you."
      )
    ).toBeInTheDocument();
    expect(
      body().queryByRole("button", { name: "Download approval record" })
    ).toBeNull();
  });
});

describe("DecisionPage — plan and KV request links", () => {
  it("asks for a note before a plan's Request changes", async () => {
    stubApi();
    renderPage(planRequestLink({ document: null as unknown as PublicPlan }));
    expect(
      await body().findByRole("button", { name: "Approve plan" })
    ).toBeInTheDocument();
    fireEvent.click(body().getByRole("button", { name: "Request changes" }));
    expect(await body().findByText("What should change?")).toBeInTheDocument();
  });

  it("labels the second button by this visit's pins on the focused artboard", async () => {
    stubApi();
    const user = userEvent.setup();
    renderPage(kvRequestLink());

    expect(
      await body().findByRole("button", { name: "Request changes" })
    ).toBeInTheDocument();
    tapPinLayer(50, 50);
    await body().findByRole("dialog", { name: /pin 1 · v1/ });
    await user.type(noteBox(), "Logo smaller");
    await user.click(body().getByRole("button", { name: "Post" }));

    expect(
      await body().findByRole("button", { name: "Send 1 pin as changes" })
    ).toBeInTheDocument();
    expect(body().queryByText("Request new version")).toBeNull();
  });
});
```

`kvRequestLink`, `deckRequestLink` and friends come from Task 12. If a selector differs in the real DOM (the pin dialog's name, the note box), copy the exact one `DecisionPage.test.tsx` uses for the same element. Do not invent one.

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/components/client-lane/DecisionPage.request.test.tsx
```

Expected:
- the deck tests FAIL: no text card, the button reads "Approve" (Task 14 wired `approveButtonLabel` but `focusedArtboard` is still KV-only, so no bar shows for a deck), and there is no record button;
- the plan test FAILS the same way;
- the KV test PASSES already (Task 14). It stays as the regression pin for E-8.

- [ ] **Step 3: `downloadPublicRecord`, `SubjectTextCard`, `RequestHero`**

Append to `src/lib/client-lane/publicApi.ts`:

```ts
/**
 * The request's approval record (spec 2026-10-06 §4.8) — 404 until every
 * item is decided or the request is withdrawn.
 */
export async function downloadPublicRecord(
  token: string,
  laneCode?: string | null
): Promise<Blob> {
  const res = await axiosPublic.get<Blob>(
    `public/share-links/${encodeURIComponent(token)}/record.pdf`,
    { headers: laneHeaders(laneCode), responseType: "blob" }
  );
  return res.data;
}
```

Create `src/components/client-lane/SubjectTextCard.tsx`:

```tsx
export interface SubjectTextCardProps {
  title: string;
  /** "Deck · v3 · 12 slides" — `textCardMeta`. */
  meta: string;
}

/**
 * Nothing to draw — a deck without a theme or slides, a plan without its
 * projection (spec 2026-10-06 §6.2, Jeff's handoff item): the title, the
 * version and the slide count, never "This deck has no style to render
 * with." The page is dark-scoped; tokens only.
 */
export function SubjectTextCard({ title, meta }: SubjectTextCardProps) {
  return (
    <section
      aria-label={title}
      className="flex aspect-video w-full flex-col items-center justify-center gap-2 rounded-2xl border border-white/10 bg-white/5 p-6 text-center font-geist"
    >
      <p className="text-textSmMedium text-text-inverse">{title}</p>
      <p className="text-textXs text-text-inverse-subtle">{meta}</p>
    </section>
  );
}
```

Create `src/components/client-lane/RequestHero.tsx`:

```tsx
"use client";

import dynamic from "next/dynamic";
import type { ComponentProps } from "react";

import type { PublicPlan } from "@/lib/campaign-planner/types";
import type { RequestHeroKind } from "@/lib/client-lane/requestDecision";

import type { DeckHero as DeckHeroComponent } from "./hero/DeckHero";
import type { KvRequestHeroProps } from "./kv/KvRequestHero";
import { SubjectTextCard, type SubjectTextCardProps } from "./SubjectTextCard";

/** Heroes load per type (NFR-4): a plan link never pays for the deck
 *  renderer, a deck link never for the planner. */
const HERO_LOADING = () => (
  <div className="aspect-video w-full animate-pulse rounded-2xl bg-white/5" />
);
const DeckHero = dynamic(
  () => import("./hero/DeckHero").then((m) => m.DeckHero),
  { ssr: false, loading: HERO_LOADING }
);
const PlanHero = dynamic(
  () => import("./hero/PlanHero").then((m) => m.PlanHero),
  { ssr: false, loading: HERO_LOADING }
);
const KvRequestHero = dynamic(
  () => import("./kv/KvRequestHero").then((m) => m.KvRequestHero),
  { ssr: false, loading: HERO_LOADING }
);

export type DeckHeroProps = ComponentProps<typeof DeckHeroComponent>;

export interface RequestHeroProps {
  kind: RequestHeroKind;
  kv?: KvRequestHeroProps;
  deck?: DeckHeroProps;
  plan?: PublicPlan;
  /** Always given: the fallback when the chosen hero has nothing to draw. */
  text: SubjectTextCardProps;
}

/**
 * A request link's hero (spec 2026-10-06 §6.2): KV's artboard grid, the
 * deck (slides, navigation, pins per slide), the plan, or the text card.
 * KV's request hero is unchanged — this only dispatches.
 */
export function RequestHero({ kind, kv, deck, plan, text }: RequestHeroProps) {
  if (kind === "kv" && kv) return <KvRequestHero {...kv} />;
  if (kind === "deck" && deck) return <DeckHero {...deck} />;
  if (kind === "plan" && plan) return <PlanHero plan={plan} />;
  return <SubjectTextCard {...text} />;
}
```

- [ ] **Step 4: Wire `DecisionPage`**

Make each change below exactly as listed:

1. **Imports.**
   - Add `FilePdf` (`@phosphor-icons/react`), `Button` (`@/components/frndos/v2`), `downloadPublicRecord` (to the `publicApi` import) and `trackApprovalRecordDownloaded`, `trackApprovalRecordDownloadFailed` (to the analytics import).
   - Add `canDownloadRecord, decisionStep, requestHeadline, requestHeroKind, subjectRequestEntries, textCardMeta, type ArtboardIntent, type RequestEntry` (alongside Task 14's two labels) from `@/lib/client-lane/requestDecision`.
   - Add `saveBlob` from `@/lib/client-lane/recordPdf`, `recordFilename` from `@/lib/client-lane/subjectRequests`, and `RequestHero` / `SubjectTextCard` from `./RequestHero` / `./SubjectTextCard`.
   - Remove `import type { ArtboardIntent } from "./kv/KvRequestHero";` and the `KvRequestHero` `dynamic(...)` const (it moved into `RequestHero`).
2. **`versionId`.** Move it BELOW `const req = …` and make it request-aware:

```tsx
  /**
   * Deck: the version pins anchor on — a request's one approval, else the
   * round's one item (C-1 `items[0]`), else `version.id` for an api that
   * predates items. KV pins per item instead.
   */
  const versionId = req
    ? (req.approvals[0]?.version_id ?? null)
    : (approvalItemsOf(data)[0]?.version_id ?? data.version.id);
```

3. **Entries.** Directly after the `artboards` memo:

```tsx
  /** What the rail decides on: KV's artboards, or a deck / plan's one item. */
  const entries = useMemo<RequestEntry[]>(() => {
    if (!req) return [];
    if (data.type === "kv_file") return artboards;
    return subjectRequestEntries(data.type, req, viewerName);
  }, [req, data.type, artboards, viewerName]);
```

   `focusedArtboard` becomes `const focusedArtboard: RequestEntry | null = req ? (entries.length === 1 ? entries[0] : (entries.find((a) => a.id === focusedItemId) ?? null)) : null;`.
   - `pinsOn` takes `(a: RequestEntry)`.
   - `allPlan` and `progress` read `entries`.
   - `goNextUndecided` and the action bar's `nextId` call `nextUndecided(entries, …)`.
   - `noteArtboard` finds in `entries`.
   - `pinItems` stays `req ? artboards : roundItems` (KV only).
4. **New replies on every request link.** `useNewAgencyReplies(token, threads, data.type === "kv_file" || req !== null)`. Update its comment: "every request link and KV".
5. **One decision rule.**

```tsx
  /** ✓ / second button on a card or in the focused view (spec 2026-10-06 §6.3). */
  const decideArtboard = (
    a: RequestEntry,
    intent: ArtboardIntent,
    source: ArtboardDecisionSource
  ) => {
    const own = pinsOn(a);
    const step = decisionStep(a.id, intent, own);
    if (step.kind === "post") {
      submitRequest(step.draft, { kind: "artboard", source, pinCount: own.length });
      return;
    }
    // Request changes with no pins needs words (spec §6.3).
    setSheet({ kind: "newVersionNote", artboardId: a.id, source });
  };
```

6. **Pins on a deck request.** In `pinnable`, the deck branch becomes `versionId !== null && (!req || entries.some((e) => !e.replaced))`.
7. **Record download.** Next to the other state: `const [recordBusy, setRecordBusy] = useState(false);`. Next to `openApproverLink`:

```tsx
  /** The approval record (spec 2026-10-06 §4.8, §6.5) — once every item is
   *  decided. PII-free analytics: subject type and side only. */
  const downloadRecord = async () => {
    if (!req) return;
    setRecordBusy(true);
    try {
      const pdf = await downloadPublicRecord(token, laneCode);
      saveBlob(pdf, recordFilename(data.subject.title, req.request.number));
      trackApprovalRecordDownloaded({ subject_type: data.type, side: "client" });
    } catch (e) {
      const err = publicApiError(e);
      trackApprovalRecordDownloadFailed({
        subject_type: data.type,
        side: "client",
        reason: failureReason(err),
        http_status: err.status,
      });
      setError("Couldn't download the record. Try again in a moment.");
    } finally {
      setRecordBusy(false);
    }
  };
```

8. **Hero.** Build the deck props once (both branches use them), then dispatch:

```tsx
  const deckHeroProps =
    data.type === "deck" && deck?.theme
      ? {
          document: data.document,
          theme: deck.theme,
          title: data.subject.title,
          playSettings: deck.playSettings,
          index: slideIndex,
          onIndexChange: (i: number) => {
            setSlideIndex(i);
            setActivePinId(null);
          },
          pins,
          draft: deckDraft,
          activePinId,
          onPlacePin:
            pinnable && versionId !== null
              ? (part: string, x: number, y: number) =>
                  placePin({ stage: DECK_STAGE, version: versionId, part }, x, y)
              : undefined,
          onSelectPin: selectPin,
        }
      : null;

  const textCard = {
    title: data.subject.title,
    meta: textCardMeta(data, entries[0]?.round ?? null),
  };

  const hero = req ? (
    <RequestHero
      kind={requestHeroKind(data)}
      kv={
        data.type === "kv_file"
          ? {
              artboards,
              pins,
              draft: pinDraft
                ? { version: pinDraft.version, x: pinDraft.x, y: pinDraft.y }
                : null,
              activePinId,
              focusedId: focusedItemId,
              onFocusChange: (id) => {
                setFocusedItemId(id);
                setActivePinId(null);
              },
              keyboardEnabled: sheet === null,
              onPlacePin: pinnable
                ? (a, x, y) =>
                    placePin({ stage: a.phase, version: a.versionId, part: a.part }, x, y)
                : undefined,
              onSelectPin: selectPin,
              onDecide: requestCanDecide
                ? (a, intent) => decideArtboard(a, intent, "card")
                : undefined,
              busy,
            }
          : undefined
      }
      deck={deckHeroProps ?? undefined}
      plan={data.type === "campaign" ? data.document : undefined}
      text={textCard}
    />
  ) : deckHeroProps ? (
    <DeckHero {...deckHeroProps} />
  ) : data.type === "kv_file" ? (
    /* the existing <KvHero …/> block, unchanged */
  ) : data.type === "campaign" ? (
    <PlanHero plan={data.document} />
  ) : (
    // A P0a deck round with no theme: same text card (spec §6.2).
    <SubjectTextCard {...textCard} />
  );
```

   Keep the existing `<KvHero …/>` JSX where the comment stands. The comment is not committed.
9. **Header.** The h1's tail: `{req ? requestHeadline(data.type, req, progress.total) : withItemCount(data.version.label, itemCount)}`.
10. **Rail.**
    - `FocusedArtboardPanel` gets `pinHint={data.type === "campaign" ? null : undefined}`.
    - Its inner `PinList` gets `partLabel={data.type === "deck" ? pinPartLabel : undefined}`.
    - After `<RequestOutcomeBanner …/>`:

```tsx
              {canDownloadRecord(req.request) && (
                <Button
                  variant="secondary"
                  size="large"
                  className="w-full"
                  leftIcon={<FilePdf size={16} />}
                  loading={recordBusy}
                  disabled={recordBusy}
                  onClick={() => void downloadRecord()}
                >
                  Download approval record
                </Button>
              )}
```

11. **Sheets.** Wrap `<VerifySheet …/>` in `{!req && ( … )}`: the magic link is for P0a round links only (spec §6.4). `CodeSheet` already mounts for every `req`. `HowBigSheet` already mounts only for `!req`.

- [ ] **Step 5: Run tests and regressions**

```bash
cd WT && bun test src/components/client-lane/DecisionPage.request.test.tsx
cd WT && bun test src/components/client-lane/DecisionPage.test.tsx
cd WT && bun test src/components/client-lane/kv/KvRequestHero.test.tsx
cd WT && bun test src/lib/client-lane/requestDecision.test.ts
```

Expected: the new file is all green; the rest match their baselines.

- [ ] **Step 6: Mutation checks**
  - In `RequestHero`, drop the `SubjectTextCard` fallback (return `null`). "renders a theme-less deck request as the text card and decides it" must FAIL. Restore.
  - Mount `VerifySheet` for request links too and make `doSubmitRequest`'s `verification_required` branch open `{ kind: "verify" }`. "asks a deck viewer for a code, never the magic link" must FAIL. Restore.
  - Render the record button unconditionally. "offers no record on a withdrawn request" must FAIL. Restore.
  - In `entries`, return `artboards` for every type. "asks for a note before a plan's Request changes" must FAIL (no entry, no bar). Restore.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "downloads the approval record once the request is decided" — pass `req.request.id` instead of the subject title to `recordFilename`.
- "labels the second button by this visit's pins on the focused artboard" — pass `changesButtonLabel(0)` in `DecisionPage`.

- [ ] **Step 7: Gate + commit**

```bash
cd WT && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-lane/(DecisionPage|RequestHero|SubjectTextCard|RequestRail)|lib/client-lane/(publicApi|requestDecision)"
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
feat(web): client page serves deck and plan approval requests

RequestHero draws the deck, the plan or a text-only card; one item rides
the KV rail and action bar; decisions follow one pins rule; request links
verify with a code, never the magic link; a decided request offers the
approval record.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Phase 7 — light mode and analytics

### Task 16: Light-mode token pass

**Files:**
- Modify: `src/app/(canvas)/decks/[deckId]/components/DeckShareLinks.tsx` (every class string)
- Modify: `src/lib/deck/chrome.ts` (new `DECK_BAR_*` constants)
- Modify: `src/app/(canvas)/decks/[deckId]/components/DeckTopBar.tsx` (the right-cluster pill and its search / Export / Share buttons use the constants)
- Test: `src/lib/client-lane/tokenHygiene.test.ts` (create)

**Interfaces:**
- Consumes: the files created or rewritten in Tasks 4–15.
- Produces: `DECK_BAR_PILL`, `DECK_BAR_ICON_BUTTON`, `DECK_BAR_TEXT_BUTTON`, `DECK_BAR_SHARE_BUTTON` (strings) in `src/lib/deck/chrome.ts`.

Spec §6.6 also names `RequestHero` and `RequestRail`. Those live on `/s/`, which is dark-scoped by design (`data-theme-scope="dark"`, #754; KV spec §11.1), so they render Midnight under every viewer theme. Their part of this pass is "tokens only, no hex". The scan below enforces it.

- [ ] **Step 1: Write the failing test**

Create `src/lib/client-lane/tokenHygiene.test.ts`:

```ts
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  DECK_BAR_ICON_BUTTON,
  DECK_BAR_PILL,
  DECK_BAR_SHARE_BUTTON,
  DECK_BAR_TEXT_BUTTON,
} from "@/lib/deck/chrome";

/**
 * Spec 2026-10-06 §6.6 / KV spec §11.1: the surfaces this feature adds or
 * touches use theme tokens — no `text-white`, no arbitrary white opacity, no
 * pixel font sizes, no hex. Run from the web root (`cd WT && bun test …`).
 * A missing file THROWS (readFileSync) — a rename must fail here, never skip.
 */
const FILES = [
  "src/app/(canvas)/decks/[deckId]/components/DeckShareLinks.tsx",
  "src/components/brands/campaign-planner/PlanViewModal.tsx",
  "src/components/client-lane/RequestHero.tsx",
  "src/components/client-lane/SubjectTextCard.tsx",
  "src/components/client-lane/RequestRail.tsx",
  "src/components/client-lane/agency/RequestForm.tsx",
  "src/components/client-lane/agency/KvRequestItems.tsx",
  "src/components/client-lane/agency/SubjectRequestItem.tsx",
  "src/components/client-lane/agency/ItemThumb.tsx",
  "src/components/client-lane/agency/ClientApprovalSlot.tsx",
  "src/components/client-lane/agency/ApprovalRequestsSection.tsx",
  "src/components/client-lane/agency/ApprovalStatusList.tsx",
];

const BANNED: Array<[string, RegExp]> = [
  ["text-white", /\btext-white\b/],
  ["arbitrary white opacity", /white\/\[0?\.\d+\]/],
  ["pixel font size", /text-\[\d+(\.\d+)?px\]/],
  ["hex colour", /#[0-9a-fA-F]{3,8}\b/],
];

function offences(source: string): string[] {
  return BANNED.filter(([, re]) => re.test(source)).map(([name]) => name);
}

describe("light-mode tokens on the surfaces this feature touches", () => {
  it.each(FILES)("%s uses theme tokens only", (file) => {
    const source = readFileSync(join(process.cwd(), file), "utf8");
    expect(offences(source)).toEqual([]);
  });

  it("keeps the deck top bar's right cluster on tokens", () => {
    expect(
      offences(
        [
          DECK_BAR_PILL,
          DECK_BAR_ICON_BUTTON,
          DECK_BAR_TEXT_BUTTON,
          DECK_BAR_SHARE_BUTTON,
        ].join(" ")
      )
    ).toEqual([]);
  });
});
```

If bun's shim has no `it.each`, replace it with `for (const file of FILES) it(\`${file} uses theme tokens only\`, () => { … })`.

- [ ] **Step 2: Run it to see it fail**

```bash
cd WT && bun test src/lib/client-lane/tokenHygiene.test.ts
```

Expected:
- `DeckShareLinks.tsx` FAILS with `["text-white", "arbitrary white opacity", "pixel font size", "hex colour"]`;
- the `DECK_BAR_*` test errors (the constants do not exist yet);
- every other file passes. Tasks 4–15 wrote them with tokens. If one fails, fix that file's offending class in this task.

- [ ] **Step 3: Convert `DeckShareLinks.tsx`**

Load `frndos-design-foundations` (Appearance tri-mode) first. Apply this map to every class string in the file, including `BARE_INPUT` and `FIELD_FOCUS_RING`:

| Before | After |
|---|---|
| `text-white` | `text-text-inverse` |
| `placeholder:text-white/40` | `placeholder:text-text-inverse-subtlest` |
| `text-white/90`, `hover:text-white/80`, `hover:text-white` | `text-text-inverse`, `hover:text-text-inverse` |
| `text-white/60`, `text-white/50` | `text-text-inverse-subtle` |
| `text-white/45` | `text-text-inverse-subtlest` |
| `bg-white/[0.04]`, `bg-white/[0.05]`, `bg-white/[0.06]` (incl. `hover:`) | `bg-white/5` |
| `bg-white/[0.08]`, `bg-white/[0.12]` (incl. `hover:`) | `bg-white/10` |
| `ring-white/[0.08]`, `ring-white/[0.12]` | `ring-white/10` |
| `focus-within:ring-[#4D8EFF]/60` | `focus-within:ring-white/40` |
| `text-[13px] font-semibold` | `text-textSmMedium` |
| `text-[12px] font-medium` | `text-textXsMedium` |
| `text-[12px]`, `text-[11px]` | `text-textXs` |
| the "Comment" / "Expired" badges: `px-[7px] py-px text-[9px] font-semibold uppercase tracking-[0.06em] text-emerald-200/80 ring-emerald-300/30` / `text-white/45 ring-white/[0.12]` | `px-1.5 text-textXs uppercase tracking-wider text-text-inverse-subtle ring-white/10` (both) |

The scan's hex rule also catches PR references in comments: `(#655)` in the `BARE_INPUT` comment reads as a hex colour. Write it as `(PR 655)`.

`bg-white/5` and `ring-white/10` are palette classes, which `theme-light.css` flips through `--theme-white-rgb`. The arbitrary forms are not reachable by the Aurora overrides (memory lesson).

- [ ] **Step 4: Deck top bar right cluster**

Append to `src/lib/deck/chrome.ts`:

```ts
/**
 * The top bar's right cluster (spec 2026-10-06 §6.6): the pill holding
 * search, presence, Export and Share — beside the client-approval slot.
 * Palette classes and text tokens only, so Midnight, Aurora and Daylight
 * all reach them.
 */
export const DECK_BAR_PILL =
  "flex items-center gap-0.5 rounded-full border border-white/5 bg-white/5 p-px backdrop-blur-md";
export const DECK_BAR_ICON_BUTTON =
  "flex h-7 w-7 items-center justify-center rounded-full text-text-inverse-subtle transition-colors hover:bg-white/10 hover:text-text-inverse";
export const DECK_BAR_TEXT_BUTTON =
  "flex h-7 items-center rounded-full px-2.5 font-geist text-textXsMedium text-text-inverse-subtle transition-colors hover:bg-white/10 hover:text-text-inverse";
export const DECK_BAR_SHARE_BUTTON =
  "flex h-7 items-center rounded-full bg-white/10 px-3 font-geist text-textXsMedium text-text-inverse transition-colors hover:bg-white/15";
```

In `DeckTopBar.tsx`, import the four constants from `@/lib/deck/chrome` (the file already imports `STATE_TINT` from there). Use them for the pill `div`, the search button, the Export button and the Share button. The health-popover amber and the Play button are outside the slot area and are left as they are.

**Mutation map: the remaining new tests.** Each must FAIL under its mutation. Restore after each.
- "<file> uses theme tokens only" — add `text-white` to `RequestForm.tsx`'s `EYEBROW`.

- [ ] **Step 5: Run, mutate, gate, commit**

```bash
cd WT && bun test src/lib/client-lane/tokenHygiene.test.ts
```

Expected: all green.

Mutation: add `text-white` to `DECK_BAR_SHARE_BUTTON`. "keeps the deck top bar's right cluster on tokens" must FAIL. Restore.

Run the tsc grep plus eslint on `DeckShareLinks.tsx`, `DeckTopBar.tsx` and `chrome.ts`. Prettier only if their develop versions are prettier-clean (see Global Constraints).

```bash
cd WT && /usr/bin/git add -A src && /usr/bin/git commit -F - <<'EOF'
style(web): theme tokens on the deck Share dialog and top-bar cluster

DeckShareLinks and the top bar's right cluster lose text-white, arbitrary
white opacities, pixel font sizes and hex; a scan test pins every surface
this feature adds or touches.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 17: Gates, manual two-device pass, Lark rows, track

**Files:**
- Modify: `docs/tracks/client-lane-deck-plan-requests.track.md`
- Modify: `docs/prd/client-lane-p0a/web.md` (contract notes copied from the api branch)

**Interfaces:**
- Consumes: everything above.
- Produces: a branch ready for review (not pushed, no PR).

- [ ] **Step 1: Analytics completeness (memory: PostHog events are part of the feature)**

Load the `frndos-analytics-events` skill and walk every interaction this feature adds against it. Then:

```bash
cd WT && /usr/bin/grep -rn "posthog.capture" src/components/client-lane src/components/brands/campaign-planner/PlanViewModal.tsx "src/app/(canvas)/decks/[deckId]/components/DeckShareLinks.tsx" || echo "no inline captures"
cd WT && /usr/bin/grep -rln "RequestApprovalPanel\b\|createApproval(" src --include='*.tsx' | /usr/bin/grep -v "agency/RequestApprovalPanel.tsx" || echo "no P0a request entry point left"
```

Expected: `no inline captures`; `no P0a request entry point left`. Decks and plans no longer fire `client_lane.approval_requested` and the other P0a events for new requests (spec §5.4). `RequestApprovalPanel` stays only as the home of `ApprovalSendStep`; deleting it belongs to the contract step (§7.3).

- [ ] **Step 2: Type, lint, tests, build**

```bash
cd WT && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
cd WT && /usr/bin/git diff --name-only origin/develop -- src | /usr/bin/grep -E "\.(ts|tsx)$" > /tmp/touched.txt; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -F -f /tmp/touched.txt
cd WT && npx eslint $(cat /tmp/touched.txt)
cd WT && /usr/bin/git diff origin/develop -U0 -- src | /usr/bin/grep -E "^\+" | /usr/bin/grep -nE "\btext-white\b|white/\[0?\.[0-9]+\]|text-\[[0-9]+px\]" || echo "no banned classes on added lines"
```

Expected:
- the first count is ≤ the Task 0 baseline;
- the second prints only lines listed as baseline in the track (`KvGeneratorLayout` 1, `KvMotionEditor` 1, plus any per-file baseline recorded for a touched file);
- eslint reports 0 errors and no new warnings on changed lines;
- `no banned classes on added lines`.

Every client-lane file runs one per invocation: the Task 0 list plus the new files.

```bash
cd WT && F=(src/lib/client-lane/round.test.ts src/lib/client-lane/pins.test.ts src/lib/client-lane/versionLabels.test.ts src/lib/client-lane/commentThreads.test.ts src/lib/client-lane/canvasApproval.test.ts src/lib/client-lane/subjectRequests.test.ts src/lib/client-lane/drain.test.ts src/lib/client-lane/planDecisions.test.ts src/lib/client-lane/requestDecision.test.ts src/lib/client-lane/tokenHygiene.test.ts src/services/client-lane.test.ts src/components/client-lane/DecisionPage.test.tsx src/components/client-lane/DecisionPage.request.test.tsx src/components/client-lane/RequestRail.test.tsx src/components/client-lane/PinLayer.test.tsx src/components/client-lane/PinNotePopover.test.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/components/client-lane/agency/RequestLinkRow.test.tsx src/components/client-lane/agency/useArtboardThumbnailSync.test.ts src/components/client-lane/agency/useRequestActions.test.tsx src/components/client-lane/agency/RequestForm.test.tsx src/components/client-lane/agency/ApprovalRequestsSection.test.tsx src/components/client-lane/agency/ApprovalStatusList.test.tsx src/components/client-lane/agency/ClientApprovalSlot.test.tsx src/components/client-lane/kv/KvLinkGallery.test.tsx src/components/client-lane/kv/swipe.test.ts src/components/client-lane/kv/KvRequestHero.test.tsx src/components/client-lane/kv/roundItems.test.ts src/components/client-lane/kv/KvRoundHero.test.tsx src/components/client-lane/kv/KvShareBoardCanvas.test.tsx src/components/studio/kv-generator/KvSharePanel.test.tsx src/components/brands/campaign-planner/SharePlanDialog.test.tsx src/components/brands/campaign-planner/SharePlanDialog.approval.test.tsx src/components/brands/campaign-planner/SavedPlansList.test.tsx src/components/brands/campaign-planner/PlanViewModal.test.tsx src/lib/campaigns-lifecycle/rowModel.test.ts src/lib/campaigns-lifecycle/approvalMenu.test.ts); for f in "${F[@]}"; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
cd WT && for f in $(/usr/bin/git diff --name-only origin/develop -- 'src/**/*.test.ts' 'src/**/*.test.tsx'); do printf "%s " "$f"; wc -c < "$f"; done
```

Expected:
- every new file: `0 fail`, no `error` line;
- every old file: exactly its Task 0 failure list;
- every changed test file < 45 000 bytes.

Build with node (memory: `bun run build` is broken on Next's runtime; the build does not type-check):

```bash
cd WT && node ./node_modules/next/dist/bin/next build 2>&1 | tail -30
```

Expected: the route table prints, including `/s/[token]` and `/s/[token]/opengraph-image`, with no `Failed to compile` / module-not-found errors.

- [ ] **Step 3: Manual two-device pass (Daffa; laptop + phone; spec §8)**

Setup:
- The api branch `feature/daffa/vc-client-lane-deck-plan-requests` runs on :9191 with its migrations applied.
- In `web/`, stop the dev server, then run `cd WT && bun dev` on :3000.
- The phone opens links via the laptop's LAN IP or a tunnel.

Record each line ✓/✗ in the track.

1. **KV unchanged.**
   - Canvas: "Ready for client" → form → send step → chip "Waiting on … · 0/N" → a popover row jumps to its artboard.
   - Share dialog: Approval requests section; the "…" menu has Download record.
   - Client phone, one artboard: "Request changes" opens "What should change?" and a note is required. A pin → "Send 1 pin as changes". Approve with a pin → the agency chip shows "Approved with fixes".
2. **Deck agency.**
   - Top bar: Request approval left of the avatars.
   - A brand-less deck: the button is disabled, its tooltip reads "Link this deck to a brand to request approval", and the Share dialog says it in words.
   - Send from the top bar → chip "Waiting on Dina · 0/1" → a popover row opens the Comments dock.
   - Share dialog: "Request 1 · v4".
   - Brand Book host (`hideHostActions`): the slot still shows.
3. **Deck drain.**
   - Open a P0a round on a deck (e.g. with the production web, or `POST v1/approvals` via the api).
   - The Share dialog shows "Round N" + the old card.
   - Send a request → the block disappears.
   - The old round's link still opens on the round branch, shows that round closed, and its Request changes path still uses "How big" (HowBigSheet).
4. **Plan agency.**
   - With the flag OFF, the lifecycle row menu has no approval items.
   - Flag ON: "Share for approval" opens the plan view with the form; send. "Copy approval link" copies `/s/…` of that request.
   - Plan header chip → inline status list.
   - "Mark approved" while the request is open → the client page shows the request closed (OQ3).
   - The Decisions block lists "Request 1 · v2" with the decision.
5. **Client, deck.**
   - A themed deck shows slides, slide navigation, and pins per slide. A theme-less deck shows the text card "Deck · vN · M slides".
   - The header reads "Deck · Needs your decision" / "<title> · v3 · Request 2 · Decide by …".
   - A pin → "Send 1 pin as changes".
   - Deciding without a lane opens the code sheet, never the magic-link sheet. Paste the code from mail → the decision lands with its pin. Reload → "Verified as … · this device".
6. **Client, plan.** PlanHero; "Approve plan"; "Request changes" requires a note.
7. **A P0a link is still decidable.** An old deck round link and an old plan round link (VerifySheet magic link on the plan) both still decide.
8. **Record.**
   - Agency "Download record" on a pending request opens a PDF.
   - The client "Download approval record" appears only after every item is decided. Not on a withdrawn request.
9. **Title / OG.** Paste a deck request link into WhatsApp or Slack: "Approve: <title> (deck, v3)", with the text card when there is no thumbnail.
10. **Light mode.** Check in Midnight, Aurora and Daylight:
    - the deck Share dialog;
    - the deck top-bar cluster + slot + form drop-down;
    - the plan view header + inline form + status list;
    - `SharePlanDialog`'s section;
    - the KV Share dialog section and request form.

    `/s/` stays dark in all three.
11. **PostHog Live Events (signed in).**
    - `client_lane.approval_request_*`, `status_chip_opened` and `status_row_jumped` carry `subject_type` `deck` / `campaign`.
    - `client_lane.approval_record_downloaded` fires on both sides.
    - No `client_lane.approval_requested` fires for a new deck/plan request.

- [ ] **Step 4: Lark taxonomy rows (Daffa — needs a signed-in session)**

List these in the track under "PENDING (human)":
- changed (new `subject_type` property, `kv_file` | `deck` | `campaign`):
  - `client_lane.approval_request_sent` (`phases` is `[]` for deck/plan) and `client_lane.approval_request_send_failed`;
  - `client_lane.approval_request_form_opened` (`source` adds `lifecycle_menu`; `ready_total` may be null);
  - `client_lane.approval_request_withdrawn` / `_withdraw_failed` / `_resent` / `_resend_failed`;
  - `client_lane.status_chip_opened` and `client_lane.status_row_jumped` (`surface` adds `deck` | `plan`; `phase` may be null);
  - `client_lane.client_artboard_decided`, `client_lane.client_decision_failed` (request links), `client_lane.client_request_completed`;
- new: `client_lane.approval_record_downloaded` {subject_type, side} and `client_lane.approval_record_download_failed` {subject_type, side, reason, http_status};
- stops for new deck/plan requests: `client_lane.approval_requested` and the other P0a round events (they fire only for drained rounds).

- [ ] **Step 4b: Copy the contract notes from the api branch, byte-identical**

The api plan's Task 14 appends a "deck and plan approval requests" block to `api/docs/prd/client-lane-p0a/api.md` on `feature/daffa/vc-client-lane-deck-plan-requests`. Copy that whole file over the web copy, then confirm the two match:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-deck-plan-requests && /usr/bin/git -C /Users/alva.e202511001/Desktop/work/frndos-agentic/api show feature/daffa/vc-client-lane-deck-plan-requests:docs/prd/client-lane-p0a/api.md > docs/prd/client-lane-p0a/web.md && /usr/bin/git -C /Users/alva.e202511001/Desktop/work/frndos-agentic/api show feature/daffa/vc-client-lane-deck-plan-requests:docs/prd/client-lane-p0a/api.md | diff - docs/prd/client-lane-p0a/web.md && echo IDENTICAL
```

Expected: `IDENTICAL`. If the api branch has no such commit yet, stop and record "contract notes pending api Task 14" in the track file. Do not hand-write the block.

- [ ] **Step 5: Track file and commit**

Update `docs/tracks/client-lane-deck-plan-requests.track.md`:
- tick Tasks 1–17;
- set the Status table to `Implementation | completed` and `PR | not_submitted`;
- append a session-log entry with:
  - commits since base (`git log --oneline origin/develop..HEAD | wc -l`);
  - gate results (tsc count vs baseline, eslint, every suite);
  - manual-pass results, or "PENDING (Daffa)";
  - the Lark rows;
  - the Task 3 placeholder note (resolved in Task 5);
  - the Task 11 primary-action note;
  - any expectation fixed during a mutation check.

Keep `status: in_progress` in the frontmatter until the PR merges (CLAUDE.md track rules).

```bash
cd WT && /usr/bin/git add docs/tracks/client-lane-deck-plan-requests.track.md && /usr/bin/git commit -F - <<'EOF'
docs(web): record gates and manual pass for deck and plan requests

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

Do NOT push and do NOT open a PR. The api PR merges first (spec §7.1), and Daffa opens both.

---

## Self-review (run against the spec, 2026-10-06)

**1. Spec coverage**

| Spec | Task |
|---|---|
| §5.1 generic components and keyed hooks; KV import-only swaps | 1, 3, 4, 5, 6 |
| §5.1 `useRequestActions` subject; copy says "artboards" only for KV | 2, 3, 5 |
| §5.1 RequestForm split: KV pills + "Already approved"; deck/plan one row "v4 · replaces v3, still waiting" | 2, 4 |
| §5.2 DeckTopBar slot (button → chip; row opens Comments; Brand Book host) | 7 |
| §5.2 DeckShareLinks section above view links; P0a card only while a round is pending; SoonCard flag-off | 7 |
| §5.2 brand-less disabled reason in top bar and dialog | 2, 5, 6 |
| §5.3 plan view header bar (title, slot, Share) | 9 (+ 11 for the live lifecycle modal) |
| §5.3 SharePlanDialog section swap; P0a block while pending | 10 |
| §5.3 lifecycle menu: Share opens the form; Copy = open request's link; manual items stay; all behind the flag | 11 |
| §5.3 PlanDecisionsBlock reads requests | 8 |
| §5.4 `subject_type` on request / chip / row events; no P0a events for new requests | 3, 17 Step 1 |
| §6.1 `requestOf` for three types; round links unchanged | 12 |
| §6.2 RequestHero (DeckHero / PlanHero / text card); header line; one-item rail | 12, 15 |
| §6.3 pins/decision rule incl. KV; approve-with-pins; HowBigSheet not on request links | 12, 14, 15 |
| §6.4 CodeSheet every request link; VerifySheet only round links | 15 |
| §6.5 Download approval record; title/OG with fallback | 12, 13, 15 |
| §6.6 light mode | 16, 17 Step 3.10 |
| §7.2 drain on the web | 7, 10, Global Constraints |
| §8 web tests (requestOf, second-button label, approve-with-pins, slot state + disabled reasons) | 2, 12, 14 |
| §8 manual | 17 |
| E-6 agency record download | 3 |
| OQ3 (decided) — web re-reads after a manual status | 11 |

**2. Placeholder scan.** No TBD/TODO. Two explicit "copy verbatim" steps name the exact source blocks: Task 4's `ArtboardsFold` / `ListFold`, and Task 8's decisions `<ul>`. Two JSX comments mark where an unchanged block stays (Task 8, Task 15 item 8) and must not be committed. Task 3's `"Key visual"` literal is a named, temporary argument that Task 5 removes and greps for.

**3. Type consistency.** `ApprovalSubject` and the `(subjectType, subjectId)` hooks/keys (Task 1) are used unchanged in Tasks 3–11. The following are each defined once and used under the same names:
- `subjectSlotState` / `SubjectSlotState` (Task 2 → 6);
- `requestSelection` / `RequestSelection` (2 → 4);
- `useRequestActions(request, subject)` (3 → 5);
- `WithdrawConfirm.note` (3 → 5);
- `ItemThumb` (4 → 5);
- `ClientApprovalSlotProps.inline` (6 → 9);
- `pendingRoundOf` (7 → 10);
- `PlanDecisionsBlock.enabled` (8 → 9);
- `RequestEntry` / `ArtboardIntent` / `decisionStep` / labels (12 → 14, 15);
- `deckRequestLink` / `planRequestLink` / `kvRequestLink` / `publicRequest` (12 → 13, 15);
- `downloadPublicRecord` (15);
- `recordFilename` (2 → 3, 15);
- `saveBlob` (3 → 15).

**4. Review Focus.** Each of the five has a named test in its owning task: brand-less → 2/5/6; drain → 7, 4; pins vs decision → 12, 15; Radix modal portals → 6, 9; theme-less deck / withdrawn record → 12, 15.

**5. Mutation coverage.** Every new test names the mutation that must fail it, either in its task's mutation step or in that task's "Mutation map" block.

