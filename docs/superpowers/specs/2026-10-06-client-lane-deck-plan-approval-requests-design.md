# Client Lane — deck and campaign plan on approval requests — Design

**Date:** 2026-10-06
**Author:** Daffa (with Claude)
**Status:** draft for review
**Ticket:** "Align deck and campaign plan approval with the new KV approval, then ship all three" (approved by Jeff). This spec is **Spec 1** of that ticket: the alignment. **Spec 2** (production rollout: deploy order, flag rollout, staging re-test, Jeff's handoff items, Lark taxonomy) is written after Spec 1 lands.
**Builds on:** `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md` (KV approval requests, merged as api#618 and web#858). That spec's D-2 ("KV only; decks and plans untouched") and open question 3 are what this spec reverses.
**References:** *Client Lane Journey* artifact (34 boards; board 5 "Deck review", board 22 "Request approval"); Client Lane vision artifact (procurement persona: "a frozen document, a verified identity, an audit trail"). Jeff's handoff artifact could not be opened from this account; its three open items are taken from the ticket text.
**Repos:** `api` (frnd-api-php), `web` (frnd-web). Branch `feature/daffa/vc-client-lane-deck-plan-requests` in both, cut from `develop`.

---

## 1. Why

KV approval moved to requests on 2026-10-01. Decks and campaign plans stayed on the P0a round model, so the three now differ everywhere an agency or client touches them:

| | KV (requests) | Deck / plan (P0a rounds) |
|---|---|---|
| Record | `approval_requests` envelope + one `approvals` row per artboard | one `approvals` row per round |
| Link | one `purpose=approval` link per request, outside the 3 view-link cap | one `role=comment` link reused for every round, counted in the cap (`ApprovalService::reuseOrMintCommentLink`) |
| Agency entry | top-bar slot + Share dialog "Approval requests" section | a card inside the share sheet; plan also a lifecycle row menu that is not behind the flag |
| Status in editor | top-bar chip + popover list | `ApprovalStatusBlock` inside the share sheet |
| Client page | request hero + rail, decision per artboard | one hero, one decision, `HowBigSheet` |
| Verification | personal link or 6-digit code once per device | plan: emailed magic link once per device; deck: none |
| Notifications | digest per request | one mail per decision |
| Approval record | none | none |

The ticket's goal: an agency learns one flow, a client sees one page, every editor shows status the same way.

## 2. Scope

**In:**

- api: requests accept `deck` and `campaign` subjects through a per-type adapter; one verification rule; digest notifications; plan status reads requests; an approval-record PDF per request for all three types.
- web agency: the KV request components become generic; deck top bar, deck Share dialog, plan view header, `SharePlanDialog` and the lifecycle row menu use them.
- web client: `/s/[token]` request branch serves deck and plan as one card; one pins/decision rule for all three types; one verification sheet.
- Light-mode tokens on every surface this spec adds or touches.

**Out (Spec 2 or later):**

- deploying to production, the flag rollout, staging re-test, Lark taxonomy rows;
- the **contract** step (§7.3): refusing rounds on `v1/approvals` and deleting the round branch;
- per-slide deck approval; several subjects in one request;
- a frozen full-content PDF (the deck's existing pptx/pdf export stays the way to get content).

## 3. Decisions taken in brainstorming (2026-10-06)

| # | Decision | Why |
|---|---|---|
| E-1 | Two specs: alignment (this) and production rollout (later). | Daffa's call; rollout depends on what alignment ships. |
| E-2 | **Approach A**: one request service with a subject adapter per type (`KvRequestSubject`, `DeckRequestSubject`, `PlanRequestSubject`). KV is refactored behind the adapter first with no behaviour change. | The types differ only in "what are the items, how is a version frozen". Separate services (approach B) would let the three drift apart again, which is what this ticket fixes. |
| E-3 | Plan entry point: a header bar on the plan view modal (Saved Plans → `PlanReadOnlyView`) holding the same slot as KV and deck. | A plan has no editor top bar. Daffa's call. |
| E-4 | Existing deck/plan rounds: **expand → drain → contract**, no data migration. New requests use the request model; old links keep working; the round code path is removed in a later release. | PostHog (60 days): deck approval events only on staging (tests), none for plans, none on frndos.com. Migrating near-zero data adds risk for nothing; closing old rounds would break links already sent. |
| E-5 | The api keeps accepting P0a rounds for deck/plan **in this release**. | The api deploys before the web. Refusing rounds now would 422 the Request button of the web still in production until the web catches up. The refusal moves to the contract step. |
| E-6 | Approval record = a one-file **audit record PDF** per request, for KV, deck and plan. Agency downloads any time; client downloads once every item is decided. | Vision artifact: "who approved what, which version, when" plus a verified identity. Content stays with the existing exports. |
| E-7 | One verification rule for request links: a decision needs a personal link or a 6-digit code once per device (30 days). Looking and pinning need nothing. | Ticket. Decks gain verification; plans move from magic link to code. |
| E-8 | One pins/decision rule for all three types, KV included: the second button reads "Request changes" with no pins and "Send N pins as changes" with N pins. | Ticket. KV's "Request new version" label is replaced so the three match; KV behaviour is unchanged. |
| E-9 | Full tests this time (no fast mode). | The KV refactor touches merged code; only regression tests make it safe. |

## 4. api

### 4.1 Envelope

- `ApprovalRequest::SUBJECT_TYPES = ['kv_file', 'deck', 'campaign']`. One request is still for one subject.
- `ApprovalRequestController` and `ApprovalRequestPreviewService` stop gating on `kv_file` and resolve an adapter from `subject_type`.
- Policies: the existing `Approval` subject authorization (`ApprovalSubject`) decides who may send for a deck or plan, as it does for P0a rounds today.

### 4.2 Subject adapter

New interface `App\Services\Approval\Subjects\ApprovalRequestSubject`:

| Method | Returns |
|---|---|
| `items(Model $subject, array $filters): Collection<RequestItem>` | Candidate items: key, label, phase (nullable), current version, thumbnail URL (nullable). |
| `freezeVersion(Model $subject, RequestItem $item, int $round, User $by): array` | `[version_type, version_id]` for the new `approvals` row. |
| `snapshot(RequestItem $item): array` | What the request stores in `approvals.snapshot` (label, thumbnail, size). |
| `brandId(Model $subject): ?int` | The subject's brand, or null. |
| `isCurrent(Approval $approval, Model $subject): bool` | Whether an approval still points at the subject's current version (for "already approved"). |

Implementations:

- **`KvRequestSubject`**: the artboard, phase, key and fingerprint logic now inside `ApprovalRequestService`, `ApprovalRequestPreviewService` and `KvArtboard*`, moved without changes. `subject_key` stays as defined in the KV spec (D-8).
- **`DeckRequestSubject`**: one item. `subject_key = null`, label "Deck". `freezeVersion` calls the existing `ApprovalService::freezeDeckVersion` (label `v{round}`), so a deck's round numbers continue from its P0a rounds (v3 → v4) and no version label repeats. Thumbnail: `deck->preview_url`, null when missing.
- **`PlanRequestSubject`**: one item, `subject_key = null`, label "Campaign plan", version = the existing `fingerprintPlan`.

`ApprovalRequestService::create` matches "the same item" by `subject_key` with null-safe comparison (`whereNull` when the key is null). Today it uses `whereIn('subject_key', $keys)`, which never matches null.

### 4.3 Preview

`GET v1/approval-requests/preview` returns the same shape for every type. For deck and plan:

- `total = 1` when the current version is neither approved nor waiting;
- `total = 0` with `already_approved` or `waiting` filled otherwise;
- `blocked_reason: 'no_brand'` when `brandId()` is null. The web shows the reason instead of a Request button that 422s (Jeff's handoff item). `store` still refuses a brand-less subject, as `ApprovalService::request` does today.

### 4.4 Sending, superseding, links

- Sending creates a request, one `purpose=approval` link (`ShareLinkService::createApprovalLink`, outside `MAX_ACTIVE_LINKS`), and one approval per item, exactly as KV.
- A pending approval of the same item is superseded. For deck and plan that includes a **pending P0a round** (`approval_request_id = null`): it closes as `not_relevant`, the same thing a new P0a round does to an old one today. Its old link then shows that round as closed.
- `reuseOrMintCommentLink` is no longer called for requests. It stays for P0a rounds until the contract step.

### 4.5 Plan status

- `CampaignPlan::getApprovalStatusAttribute` reads the newest approval for the plan whether it came from a round or a request (both are `approvals` rows with `subject_type = 'campaign'`).
- Editing a plan (`CampaignPlansController` `reopenPlanForEdit`, MCP `CampaignPlanToolController`) closes a pending request approval as `not_relevant` and recalculates the request roll-up.
- Manual status (`CampaignPlansController::approval` → `applyPlanStatus`) stays for the agency.

### 4.6 Verification

- `ClientVerificationCodeService::approvalLink()` accepts `purpose=approval` links of all three types.
- `PublicShareLinkController::decideOnRequest` already returns 403 without a lane; it now serves deck and plan requests unchanged.
- The deck guest path (name + email, no check) and the plan magic-link path (`VerificationRequiredException`, `public/lane/magic-link`) remain only for P0a round links.

### 4.7 Notifications

Deck and plan requests use the KV request notifier: `requestSent`, `requestResent`, `requestDigest` (`SendApprovalRequestDigest`, 15 minutes or on completion) and `requestDeferred`. `decided()` keeps serving P0a rounds only. Mail copy names the subject type ("deck", "campaign plan", "artboards").

### 4.8 Approval record PDF

- **Agency:** `GET v1/approval-requests/{id}/record.pdf`, with the same authorization as `index`.
- **Public:** `GET public/share-links/{token}/record.pdf` on a `purpose=approval` link. It returns 404 until the request is `complete` or `withdrawn`.
- **Rendering:** server-side with `barryvdh/laravel-dompdf` (already used by `InvoiceService`) from a Blade view. It is generated on demand and not stored.
- **Header:**
  - brand;
  - subject title and type;
  - "Request N";
  - sender;
  - approvers;
  - sent at;
  - decide by;
  - status;
  - a **Final** stamp when every item is decided.
- **One block per item:**
  - thumbnail, or a text-only box when there is none;
  - label and version;
  - verdict;
  - who decided and when;
  - how they were verified: "personal link" or "code · this device";
  - the note;
  - the pins, numbered, each with its text.
- **Footer:** generated-at time and request link. Internal-only (Team only) comments never render.

### 4.9 Resolver

`PublicShareLinkController::show` already branches on `purpose=approval`, so deck and plan requests reach the request branch. `ApprovalRequestPresenter::publicPayload` gains the per-type render context the round branch builds today:

- deck: `data.deck` with theme, slide_themes and play_settings;
- plan: the plan projection.

## 5. web — agency side (editors)

### 5.1 Generic components

| Generic | From | Change |
|---|---|---|
| `ApprovalRequestsSection` | `KvApprovalRequestsSection` | Takes `subject: { type, id, name }`; the thumbnail is a slot; KV keeps `KvArtboardThumb`. |
| `ClientApprovalSlot` | `KvClientApprovalSlot` | Takes `subject`. KV-only props (`onHoverReadySet`, `onJump` to an artboard, `useArtboardThumbnailSync`) become optional. |
| `ApprovalStatusList` | `KvApprovalStatusList` | One row for deck/plan. |
| `RequestForm` | `KvRequestForm` | Shared part: approvers, message, Decide by, `ApprovalSendStep`. KV adds the phase pills and "Already approved · N". Deck/plan show one item row: thumbnail, title, and "v4 · replaces v3, still waiting" when it replaces a pending approval. |
| `useRequestActions` | — | `subject_type` comes from the subject, not hardcoded `kv_file`; copy says "artboards" only for KV. |

- `services/client-lane.ts`: `useApprovalRequestPreview`, `useApprovalRequests`, `useCreateApprovalRequest` and `useWithdrawApprovalRequest` take `(subjectType, subjectId)`, and their query keys include both.
- `KvReadyForClientTray`, the verdict chips on artboards and the artboard jump stay KV-only.
- KV keeps its behaviour; only its imports change.

### 5.2 Deck

- **`DeckTopBar`:** `ClientApprovalSlot` in the pill left of `PresenceAvatars`, where KV has it.
  - No request yet: a **Request approval** button.
  - After one: a chip, e.g. "Waiting on Dina · 0/1", "Approved" or "Changes".
  - Clicking a row in the popover opens the Comments dock on the deck's pins.
  - With `hideHostActions` (Brand Book host) the slot still shows.
- **`DeckShareLinks`:** the "Approval requests" section sits above View links.
  - The "Request approval / Freeze this version" card and `ApprovalStatusBlock` render only while the deck still has a pending P0a round (drain).
  - The flag-off `SoonCard` stays.
- **Brand-less deck:** the button is disabled and shows the reason "Link this deck to a brand to request approval", in both the top bar and the dialog.

### 5.3 Campaign plan

- **Plan view modal** (`SavedPlansList` → `PlanReadOnlyView`): a header bar with the plan title, `ClientApprovalSlot` and Share.
- **`SharePlanDialog`:** section "(0) Request approval" and `ApprovalStatusBlock` are replaced by `ApprovalRequestsSection`. The P0a block shows only while a round is pending.
- **Lifecycle row menu** (`CampaignsLifecycleView`):
  - "Share for approval" opens the plan view modal with the request form open. It no longer calls `createApproval` and copies the URL.
  - "Copy approval link" copies the newest open request's link.
  - "Mark approved", "Request changes" and "Re-open review" stay for the agency.
  - Every approval item in this menu is now behind `show-client-lane`.
- `PlanDecisionsBlock` reads requests.

### 5.4 Analytics

- `client_lane.approval_request_*`, `status_chip_opened` and `status_row_jumped` carry the real `subject_type`. Today it is `kv_file` or null.
- Deck and plan stop sending the P0a events (`approval_requested` and the rest) for new requests.

## 6. web — client side (`/s/[token]` → `DecisionPage`)

### 6.1 Routing

`requestOf(data)` (`lib/client-lane/requests.ts`) accepts `kv_file`, `deck` and `campaign`. P0a round links keep the current round branch unchanged.

### 6.2 Deck and plan as one card

- `KvRequestHero` becomes `RequestHero`. For one-item requests it renders:
  - deck: the existing `DeckHero` (slides, slide navigation, pins per slide on `DECK_STAGE`);
  - plan: the existing `PlanHero`.
- The header reads "Deck · v3 · Request 2 · Decide by Thu" (journey board 5).
- `RequestRail` / `RequestActionBar` serve one item: no artboard list and no "Approve all N".
- **No thumbnail or no theme:** a text-only card (title, version, slide count) replaces "This deck has no style to render with." This is Jeff's handoff item.

### 6.3 Pins and decision — one rule for all three types

- Pins are separate from the decision. Placing a pin decides nothing.
- **Primary button:** "Approve deck", "Approve plan" or "Approve" (per artboard). Approving with pins on that version is stored as `approved_with_changes`, as KV does today.
- **Second button**, from the client's own pins on that item's version:
  - **no pins:** "Request changes". It opens the note sheet, and a note is required (KV's `NewVersionNoteSheet`, retitled);
  - **N pins:** "Send N pins as changes". It posts `changes_required` with those pins; no note is required.
- KV's "Request new version" label is replaced by the same rule. The outcomes KV stores are unchanged.
- `HowBigSheet` is not used on request links.
- The agency side shows pins without a decision as "Feedback, no decision yet".

### 6.4 Verification

`CodeSheet` is mounted for every request link (today it is mounted only for KV, under ruling R-D14). `VerifySheet` (magic link) is mounted only on P0a round links.

### 6.5 PDF, title, OG

- **Download approval record** appears on the client page once every item in the request is decided.
- Request links for deck and plan get KV's title and OG format, e.g. "Approve: Ramadan 2027 strategy (deck, v3)". The existing text card is the fallback when there is no thumbnail.

### 6.6 Light mode

Every component this spec adds or touches uses theme tokens: `DeckShareLinks`, the slot area of `DeckTopBar`, the plan view header, `RequestHero`, `RequestRail` and `RequestForm`. Today `DeckShareLinks` and `DeckTopBar` hardcode `text-white` and must be converted. Each surface is checked in Midnight, Aurora and Daylight.

## 7. Order of work and drain

### 7.1 Phases

| # | Phase | Repo | Done when |
|---|---|---|---|
| 0 | KV smoke for Parts B/C/D (the ticket's blocker) | — | KV DoD checklist passes locally |
| 1 | `KvRequestSubject` refactor, no behaviour change | api | KV tests green before and after; KV responses identical |
| 2 | Deck/plan adapters, preview `blocked_reason`, verification, notifier, plan status, reopen-on-edit | api | Pest per adapter green |
| 3 | Approval record PDF, agency + public | api | PDF for all three types |
| 4 | Generic web components; KV import swap | web | KV looks and works the same |
| 5 | Deck top bar + Share dialog; plan header, `SharePlanDialog`, lifecycle menu (+ flag gate) | web | Deck/plan request reaches the SendStep |
| 6 | Client page: request branch for deck/plan, pins rule, `CodeSheet`, text-only card, PDF button | web | A client decides on a deck and a plan |
| 7 | Light-mode pass + analytics `subject_type` | web | Midnight / Aurora / Daylight checked |

The api PR merges before the web PR. Both target `develop`.

### 7.2 Drain (this release)

- `v1/approvals` keeps creating, withdrawing and resending P0a rounds for deck and plan. The new web never calls it for new requests; only the web still in production does.
- Old round links keep the round branch, guest/magic-link verification and `HowBigSheet`.
- Sending a request supersedes a pending P0a round of the same subject (§4.4).

### 7.3 Contract (separate ticket, after Spec 2 ships)

1. A production query shows no pending deck/plan round (`approval_request_id IS NULL AND status = 'pending'`).
2. `ApprovalController::store` refuses `deck` and `campaign` with `use_approval_requests`, as it does for KV.
3. The round branch in the resolver and `DecisionPage`, `HowBigSheet`, `VerifySheet`, `ApprovalStatusBlock`, the magic-link endpoints and `reuseOrMintCommentLink` are deleted.

## 8. Testing

**api (Pest).** Run on the scratch Postgres with explicit file paths, one process at a time (see the api Feature-test lesson in memory). Mutation-check each new test once.

- KV regression: preview, send, supersede, roll-up, decision, digest. Snapshot the JSON before the phase-1 refactor and compare after.
- Deck and plan adapters:
  - preview total, already approved and waiting;
  - `no_brand`;
  - send creating its own link outside the cap;
  - supersede of a pending P0a round;
  - round numbering continuing (v3 → v4).
- Verification: a 403 without a lane for each type; code verify then decide; personal link decides.
- Plan: status from a request; edit closes a pending request approval.
- PDF: 200 with `application/pdf` for each type; public 404 before completion; no Team-only comment in the output.
- Drain: a P0a deck round can still be created and decided.

**web (`bun test`).** Pure rules only:

- `requestOf` for the three types;
- the second-button label (none / N pins);
- approve-with-pins outcome;
- slot state and disabled reasons (`no_brand`, already approved, waiting).

**Manual (two devices, laptop + phone).** The ticket's DoD for KV, deck and plan:

- same buttons, form and send step;
- same client page;
- chips, counts and Share dialog in agreement;
- one verification rule;
- a P0a link still decidable;
- light mode readable.

## 9. Open questions

1. **Jeff's handoff artifact** could not be read from this account. If it lists items beyond the three in the ticket, they belong in Spec 2.
2. **frndos.com fired KV request events since 2026-10-05**, although web#858 is not on `origin/production`. Before Spec 2, confirm which branch frndos.com deploys from.
3. **Plan lifecycle "Mark approved".** Does a manual agency approval while a request is open close that request's approval, or only set the plan status? Proposal: it closes the pending approval as `not_relevant` and sets the status, so the client page shows the request as closed rather than still asking.
