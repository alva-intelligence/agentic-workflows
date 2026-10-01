# Client Lane — KV approval requests (per-artboard approval) — Design

**Date:** 2026-10-01
**Author:** Daffa (with Claude)
**Status:** draft for review
**Supersedes:** `docs/superpowers/specs/2026-09-30-client-lane-multi-item-approval-design.md` (file-level round + `approval_items`). That model is the guide's rejected "Option 2".
**Follows:** the guide *KV approval rework — the ready marks are the request* (Novi, 30 Sep 2026, plan for review) and its prototype *KV Approval Rework — Prototype* (38 frames).
**Repos:** `api` (frnd-api-php), `web` (frnd-web). Branch `feature/daffa/vc-client-lane-multi-item` in both, continued (nothing on it is pushed).

---

## 1. Why

P0a approved KV per file, and our multi-item branch kept that. A file-level round has three problems:

- Re-sending one resize opens a new round for the whole file, so the master's approval becomes history.
- A second request closes the first one silently, because a file may only have one pending round.
- "Is this artboard approved?" has no direct answer, because a board's id changes on every Craft iteration.

On 30 Sep Jeff decided:

- approval is **per artboard**;
- there is **no toggle in the Create-link form**;
- ready marks stay the only thing that decides what a client sees (Share Link PRD Decisions 2 and 7).

This spec builds the guide's recommended model on top of those decisions.

## 2. Scope

The work is one spec in four parts. Each part has its own implementation plan, and the parts ship in order:

| Part | What | Repos |
|---|---|---|
| **A** | Data model and api: `approval_requests` plus one approval per artboard, one token per request, roll-up, digest. Client page with a decision per artboard. Share dialog "Approval requests" section and the request form. Remove the New-link toggle. | api + web |
| **B** | Canvas tray, top-bar "Ready for client" button, status chip and popover, verdict chips on artboards. | web |
| **C** | Agency Comments dock: Client label and pill, Team-only filter, "Client sees this / Team only" reply toggle, team threads default to Team only while a request is open. | web (+ small api check) |
| **D** | Verification code once per device for KV request decisions (6 digits, 10 minutes, 30-day lane). | api + web |

**KV only.** Decks and campaign plans keep the P0a round model unchanged. Their approvals have `approval_request_id = null` and `subject_key = null`.

**Out of scope:**

- decks and plans moving to requests, and per-slide deck approval;
- bulk marking (Share Link PRD open question 14);
- an AI-drafted request message;
- a reply digest email to the client.

## 3. Decisions taken in brainstorming (2026-10-01)

| # | Decision | Why |
|---|---|---|
| D-1 | **Storage approach 2**: a new `approval_requests` table (the envelope) plus one `approvals` row per artboard per round. | One meaning per table. An `approval` is always "a decision on one subject, with its own rounds". A request is always "what was sent together". Approach 1 (reuse `approvals` as the envelope and `approval_items` as per-artboard approvals) would make both tables mean different things per subject type. |
| D-2 | KV only; decks and plans untouched. | Daffa's call; keeps P0a deck and plan paths as merged. |
| D-3 | Continue on the existing branch. Replace the three `2026_09_30_*` migrations. | Unpushed. The dev DB `approvals` table is empty. |
| D-4 | Agency notification is a **digest** per request: when the client finishes, or 15 minutes after their last decision. "I need more time" notifies immediately. | The guide's proposal. Eight per-artboard emails is noise. |
| D-5 | The client has two decisions per artboard: **Approve** / **Request new version**. Approve with pins is stored as `approved_with_changes`. Request new version without pins requires a note. HowBigSheet is retired **for KV**. | The guide's chosen frames D1–D4. |
| D-6 | "I need more time" applies to the whole request. | The deadline belongs to the request (guide open question; screens assume it). |
| D-7 | A request's contents are every artboard marked ready whose current version is not approved, narrowed by phase pills. There is no per-artboard checklist. | Share Link PRD Decision 2; guide §05. |
| D-8 | The artboard key is the chain's first generation for boards, the row id for resize tiles, and (project, ratio) for motion. | Stable across Craft iterations and re-exports (§4.2). The guide's open question; proposed answer for Jeff. |
| D-9 | B, C and D are included in this spec as separate parts and plans. D ships last. | Daffa's call. D changes the product vision and is still "awaiting Jeff" in the guide. |

## 4. Part A — data model and api

### 4.1 Tables

**New `approval_requests`** (KV only):

| Column | Type | Notes |
|---|---|---|
| `id` | ulid PK | |
| `workspace_id` | ulid FK workspaces, cascade | |
| `brand_id` | char(26) FK brands, cascade | |
| `subject_type` | string(32) | `kv_file` |
| `subject_id` | ulid | the studio file |
| `number` | unsigned smallint | 1, 2, … per subject; `UNIQUE(subject_type, subject_id, number)` |
| `requested_by` | ulid FK users, null on delete | |
| `policy` | string(16) | `optional` (no named approvers) or `required` |
| `approvers` | jsonb, default `[]` | same shape as P0a: `{user_id, lane_link_id, email, name}` |
| `message` | text, nullable | ≤ 500 chars, as in P0a |
| `share_link_id` | ulid FK share_links, null on delete | the request's own token (§4.4) |
| `sent_at` | timestamptz, nullable | |
| `decide_by` | timestamptz, nullable | optional deadline shown to the client |
| `deferred_until` | timestamptz, nullable | "I need more time" for the whole request |
| `deferred_note` | text, nullable | |
| `status` | string(32), indexed | roll-up (§4.3) |
| `resolved_at` | timestamptz, nullable | |
| `last_decision_at` | timestamptz, nullable | digest bookkeeping (§4.7) |
| `digest_sent_at` | timestamptz, nullable | digest bookkeeping |
| `created_at`, `updated_at` | timestamptz | |

**`approvals`** (existing P0a table; new nullable columns):

| Column | Type | Notes |
|---|---|---|
| `approval_request_id` | ulid FK approval_requests, cascade, nullable, indexed | null for deck and plan |
| `subject_key` | string(160), nullable | KV artboard key (§4.2); null for deck and plan |
| `phase` | string(16), nullable | `sketch`, `craft`, `resize`, `motion` |
| `label` | string(160), nullable | display text, e.g. `Resize · TikTok · 1080×1920`; never parsed |
| `snapshot` | jsonb, nullable | the payload item exactly as rendered at send time |

- **Existing columns, as used by KV rows:**
  - `subject_type = kv_file`, `subject_id = file`;
  - `subject_version_type` / `subject_version_id` = the rendered version (`kv_generation` tip / `kv_resize_export` row / `kv_motion_export` newest row);
  - `round` = this artboard's round (1, 2, …);
  - `status`, `resolved_at`, `resolved_by_decision_id`, `supersedes_approval_id` as in P0a.
- **Columns owned by the request:** `policy` and `approvers` are **copied once** from the request at creation and never updated, so the P0a per-approval resolution (FR-3) runs unchanged. `message`, `share_link_id`, `sent_at` and `deferred_*` stay null on KV rows; the request owns them.
- **Unique index:** `UNIQUE(subject_type, subject_id, round)` becomes a unique **expression index** on `(subject_type, subject_id, COALESCE(subject_key, ''), round)`. Deck and plan rows keep their old uniqueness because `subject_key` is null for them.

**`approval_decisions`:** unchanged. One decision is on one approval, which for KV means one artboard. Our branch's `approval_item_id` column is removed.

**`share_links`:** new `purpose` string(16), NOT NULL, default `share`. The values are `share` and `approval`.

**Removed from our branch:** the `approval_items` table, `approval_decisions.approval_item_id` and the backfill. The migrations `2026_09_30_120000`, `120100` and `120200` are deleted and replaced by:

- `create_approval_requests_table`;
- `add_request_columns_to_approvals` (columns plus the unique swap);
- `add_purpose_to_share_links`.

Dev DB: roll back the three old migrations, then migrate. This is asked at execution time.

### 4.2 Artboard key (`subject_key`)

| Phase | Key | Source |
|---|---|---|
| sketch / craft | `board:{first generation id of the chain}` | `metadata.kv_canvas.artboards[tip].version_ids[0]`; a marked id resolves to its tip as `KvSnapshotService::resolvePublicBoards` already does |
| resize | `resize:{kv_resize_exports.id}` | regenerating overwrites the same row |
| motion | `motion:{kv_motion_project_id}:{ratio}` | a re-export appends a row; the pair is stable (`KvSharePayloadService::resolveMotionClips`) |

**Board keys in more detail:**

- A board that is restored to an older version keeps its chain, so it keeps its key.
- A board forked into a new artboard starts a new chain, so it gets a new key.
- If `version_ids` is missing, the tip id is the key.

This is recorded as an open question for Jeff (§9).

### 4.3 Rules

**One pending approval per artboard.**

- KV: at most one `pending` approval per `(subject_type, subject_id, subject_key)`. This is enforced in the service under a lock, the same way the P0a one-pending rule is enforced.
- Deck and plan keep the per-subject rule.

**Supersede.** When a new request contains an artboard that is still pending in another request:

1. That approval becomes `not_relevant` with `resolved_at`.
2. The new approval gets `supersedes_approval_id` and `round = previous round + 1`.
3. The other request's roll-up is recalculated.

The other request stays open for its remaining artboards.

**Per-approval resolution.** This is P0a FR-3 per approval:

- `optional`: the first resolving decision settles the artboard.
- `required`: only named approvers count, and any `changes_required` settles immediately. Otherwise the artboard settles once every named approver has decided.
- Advisory decisions never settle anything.

**Request roll-up**, recalculated in the same transaction as every decision, supersede or withdraw:

1. Ignore approvals that are `not_relevant` **because they were superseded**.
2. If any remaining approval is `pending`, the status is `pending`.
3. Otherwise:
   - `changes_required` if any approval is;
   - else `approved_with_changes` if any approval is;
   - else `approved`.
4. If every approval was superseded or withdrawn, the status is `not_relevant`.
5. `resolved_at` is set when the request leaves `pending`.

**Withdraw.** Every pending approval in the request becomes `not_relevant`, and the request becomes `not_relevant`.

**Revoke.** Revoking a request's link withdraws the request. The existing `ShareLinksRevoked` → `WithdrawRoundsOnRevokedLinks` listener is extended to requests. The P0a behaviour for deck and plan links stays.

### 4.4 Request link

- **Minting:** every request mints its own `share_links` row with `purpose = approval`, `role = comment`, `expires_at = null` and `phases` = the request's phases. The token is not reused across requests.
- **Not counted as a view link:** `ShareLinkService::assertUnderLimit` (MAX_ACTIVE_LINKS = 3) and the KV share-link index (`GET v1/studio/files/{id}/share-links`) count and list only `purpose = share`.
- **What the link shows:** the request it was sent for, forever. An old WhatsApp link keeps showing that request, including its final state.

### 4.5 Agency endpoints (`v1/approval-requests`, KV only)

The same auth as `v1/approvals` for the subject.

**`GET v1/approval-requests/preview?subject_type=kv_file&subject_id={file}&kv_phases[]=…`** shows what a request would contain. With no `kv_phases`, every phase that has eligible artboards is included.

```json
{ "data": {
  "phases": [ { "phase": "craft", "count": 1 }, { "phase": "resize", "count": 5 } ],
  "items": [ { "subject_key": "resize:01…", "phase": "resize", "label": "Resize · TikTok · 1080×1920",
               "version_id": "01…", "thumbnail_url": "…|null",
               "replaces": { "request_number": 1, "round": 1 } | null } ],
  "already_approved": [ { "subject_key": "…", "label": "…", "version_id": "…" } ],
  "total": 6
} }
```

- **Eligible** = marked ready in the selected phases, resolved to the rendered item (`KvSharePayloadService::itemsFor`), minus artboards whose latest approval is `approved` / `approved_with_changes` **on the same `subject_version_id`**.
- **`replaces`** is set when the artboard has a pending approval in another request.

**`POST v1/approval-requests`**

```json
{ "subject_type": "kv_file", "subject_id": "…", "kv_phases": ["craft","resize"],
  "approver_emails": ["dina@brand.co.id"], "message": "…", "decide_by": "2026-10-03" }
```

The steps:

1. Freeze the preview's eligible items (snapshot per item).
2. Supersede pending approvals that share a `subject_key`.
3. Create one request plus N approvals.
4. Mint the link.
5. Mint personal lanes for the approvers (P0a `ensureClientUser` / `mintLaneLink`).
6. Mail the approvers (`ApprovalRequestMail`, label `Request {n} · {count} artboards`).

`201`:

```json
{ "data": { "request": AgencyRequest, "share_url": "…",
            "approvers": [ { "email", "name", "user_id", "personal_url", "mail_sent" } ] } }
```

Errors:

- `422 { "code": "nothing_ready" }`: nothing is eligible.
- `422 { "code": "too_many_items", "max": 50 }`.
- `422` validation on `kv_phases`, `approver_emails`, `message` (≤ 500), `decide_by` (a future date).
- `already_a_member` as in P0a.

**`GET v1/approval-requests?subject_type=kv_file&subject_id=…`** returns every request on the file. Open requests come first, then newest first.

```json
AgencyRequest = { "id", "number", "status", "policy", "message", "sent_at", "decide_by",
  "deferred_until", "deferred_note", "resolved_at", "created_at",
  "share_url", "share_link_active": bool,
  "counts": { "approved": n, "approved_with_changes": n, "changes_required": n, "pending": n, "superseded": n },
  "approvers": [ { "name", "email", "user_id", "personal_url": "…|null", "decided": bool } ],
  "approvals": [ { "id", "subject_key", "phase", "label", "round", "version_id", "thumbnail_url",
                   "status", "superseded_by_request_number": n|null, "pin_count": n,
                   "decisions": [ ApprovalDecision… ] } ] }
```

- `personal_url` is null while the link or the lane is not active, as on the branch today.
- `pin_count` counts every client pin on that approval's version that was created at or after the approval was created.

**`POST v1/approval-requests/{id}/withdraw`** and **`POST v1/approval-requests/{id}/resend`** behave as the P0a approval endpoints do, applied to a request.

**`POST v1/approvals` with `subject_type = kv_file`** now returns `422 { "code": "use_approval_requests" }`. `GET v1/approvals` for `kv_file` returns only legacy rows (none in practice). Decks and plans are unchanged.

### 4.6 Public endpoints (`/s/{token}`)

**C-1 `GET public/share-links/{token}`.** For a link with `purpose = approval`, the response has `approval: null` and adds:

```json
"request": { "id", "number", "status", "message", "decide_by", "deferred_until", "deferred_note",
             "approvers": [ { "name", "decided" } ], "counts": { … } },
"approvals": [ { "id", "phase", "label", "round", "version_id", "status",
                 "snapshot": {…}, "replaced": bool, "decisions": [ ApprovalDecision… ] } ]
```

- `document` is built from the snapshots, as on the branch today.
- `items` and `version` stay for compatibility. `items[]` mirrors `approvals[]`.
- Deck, plan and KV **view** links are unchanged.

**C-3 `POST public/share-links/{token}/decision`.** For a request link the body is:

```json
{ "approval_ids": ["…"], "outcome": "approved" | "changes_required" | "deferred",
  "note": "…", "pins": ["comment ids"], "guest_name": "…", "guest_email": "…", "deferred_until": "YYYY-MM-DD" }
```

- **`approved` / `changes_required`:** `approval_ids` is 1..50 ids of this request.
  - Ids that are no longer pending are skipped. The response lists, per id, `decided`, `skipped_closed` or `skipped_replaced`.
  - `approved` with ≥ 1 pin for that approval is stored as `approved_with_changes`.
  - `changes_required` with no pin and no note returns `422 { "code": "note_required" }`.
  - `pins` are the **decider's own** pins (the comment ids the page placed this visit, as P0a FR-35). They are matched per approval: only pins anchored on that approval's version go into that decision, and "with ≥ 1 pin" counts only those.
- **`deferred`:** no `approval_ids`. It sets the request's `deferred_until` / `deferred_note`. The ≤ 14-day cap is from P0a.
- **Advisory** is decided per approval by the P0a rule.
- **Response:** `{ "results": [ { "approval_id", "result", "decision": ApprovalDecision|null } ], "request": PublicRequest, "approvals": [ … ] }`.
- A KV request decision without a verified identity returns 403 `verification_required` after part D (§7).

**C-4 comments.**

- A new root pin is accepted only if its anchor's version segment is one of the request's `approvals[].version_id`.
- A pin is listed and accepted as a decision pin only if `created_at >=` its approval's `created_at`. This is today's round rule, applied per approval.

### 4.7 Notifications (digest)

1. Every non-advisory **and** advisory decision on a request sets `approval_requests.last_decision_at = now()` and dispatches `SendApprovalRequestDigest(request_id, stamp)`, delayed 15 minutes, on the `default` queue.
2. When the job runs:
   - If `last_decision_at > stamp`, it skips, because a newer job will send.
   - Otherwise it sends one `ApprovalRequestDigestMail` and one inbox notification (`Kind::ApprovalDecided`, reused) to the requester. The notifier's P0a recipient rule applies.
   - The digest lists the decisions made since `digest_sent_at`, then sets `digest_sent_at`.
3. When the roll-up leaves `pending` (everything decided), the digest is sent **immediately**. Later jobs then find nothing new and send nothing.
4. `deferred` notifies immediately, as in P0a (`ApprovalDecidedMail`, "asked for more time").
5. Content of the digest: subject `{Client} reviewed Request {n} — {file}`, the counts line `5 approved · 1 new version asked · 2 still open`, one line per artboard decided since the last digest with its pin count, and a link to the file.

### 4.8 Contract notes

The multi-item notes in `docs/prd/client-lane-p0a/api.md` and `web.md` are rewritten for this model and stay byte-identical in both files. They gain a **name map for the guide**:

| Guide | This spec |
|---|---|
| `approval_requests` (message, approvers, link, sent, deadline, deferred) | `approval_requests` |
| `approvals.approval_request_id`; subject becomes the artboard | `approvals.approval_request_id` + `subject_key` (subject stays the file) |
| "artboard subject type and key" | `subject_type = kv_file` + `subject_key` (§4.2) |
| one comment token per request, outside MAX_ACTIVE_LINKS | `share_links.purpose = approval` |

## 5. Part A — web

### 5.1 Client page for a request link

`DecisionPage` branches on `data.request`. Deck, plan and KV view links keep today's page.

**Laptop** (prototype frames 6–9, D1, D2). The two-column page stays: content on the left, a sticky 360px rail on the right.

- **Left: a grid of artboards grouped by phase**, built on `KvPhaseGrid`. Each card shows:
  - its state: `No decision yet`, `Approved`, `Approved with fixes`, `New version asked`, or `Replaced by a newer version` (greyed, not decidable);
  - quick ✓ (approve) and ✎ (request new version) controls.
- **The rail for the request:**
  - the agency message;
  - `2 of 8 decided`;
  - `Decide by Thu 3 Oct` when set;
  - **Approve all** — it approves only undecided artboards on which **this viewer** has placed no pins. Its label reads `Approve 7 · 1 has pins`; the skipped artboard keeps its own decision;
  - **I need more time** (`MoreTimeSheet`, request-level).
- **Clicking a card opens it focused**, using `KvFocusedItem` with the pin layer, the filmstrip and motion controls. The rail then shows:
  - that artboard's pin threads (`PinList` / `CommentThread` reply, existing);
  - `3 pins included`;
  - **Approve** and **Request new version**;
  - **Next undecided**.

**Phone** (frames 5, 10, 11, D3, D4):

- one column of cards, a header `5 of 8`, and a sticky **Approve all**;
- tapping a card opens it full screen with pins, with a bottom bar of Approve / Request new version.

**Decision behaviour:**

- Every decision is saved the moment it is made. It posts with `approval_ids: [id]`; Approve all posts with the eligible ids.
- **Request new version without pins** opens a small sheet asking "What should change?" (required, ≤ 2000 chars). With pins it posts at once.
- **Completion summary:** `All 8 reviewed · 6 approved · 2 new versions asked`.
- **Kept from the branch:** the advisory card (per request), the approver hint ("Email me my link"), `NameGateSheet` on the first write, the comment threads and replies, and the dark-scope token reset.
- `HowBigSheet` and `DecisionBar` are not rendered for request links. They stay for deck and plan.

### 5.2 Share dialog (`KvSharePanel`)

**Two sections:**

1. **Approval requests** (first).
   - A header button **Request approval · {n} new ready**, where `n` is the preview total. When it is disabled it says why: "Mark artboards ready on the canvas first", or "Everything marked is approved or waiting".
   - One row per request, open first: `Request 2 · 1 artboard · Waiting on Dina · Decide by Thu`, with Copy link.
   - An expanded row shows per-artboard rows (verdict, who, when, pin count), approvers with Copy personal link, and **Resend** / **Withdraw** for an open request. This reuses the redesigned `ApprovalStatusBlock` building blocks (pills, `DecisionRow`, avatars, earlier answers fold).
2. **View links** (below). Unchanged, `1/3`. The **Request approval toggle in the New-link form is removed** (revert of `6ed9386e8` in behaviour), and the form is access-only again.

**Request form** (`RequestApprovalPanel`; the single select is removed):

- phase pills with counts from the preview (`Craft 1 · Resize 5 · Motion 2`);
- `Already approved · 3` collapsed;
- per-item replaced notes (`TikTok 9:16 — replaces v1, still waiting`);
- approver chips, message, **Decide by** (optional date);
- Send, then the existing `SendStep` (WhatsApp · Copy link · Email).

For `kv_file`, `ApprovalStatusBlock` is no longer rendered under the view links. Deck and plan keep it.

### 5.3 Analytics (`client-lane-events.ts`)

| Event | Properties |
|---|---|
| `client_lane.approval_request_form_opened` | `{source: "share_dialog" \| "tray" \| "top_bar", ready_total}` |
| `client_lane.approval_request_sent` | `{request_number, artboard_count, phases, approver_count, has_deadline}` |
| `client_lane.approval_request_send_failed` | `{reason, http_status}` |
| `client_lane.approval_request_withdrawn` / `_withdraw_failed` / `_resent` / `_resend_failed` | |
| `client_lane.client_artboard_decided` | `{outcome, pin_count, source: "card" \| "focused"}` (client side) |
| `client_lane.client_approve_all` | `{count, skipped_with_pins}` |
| `client_lane.client_decision_failed` | `{reason, http_status}` |
| `client_lane.client_request_completed` | `{artboard_count, changes_count}` |

Each event gets a taxonomy row in Lark.

## 6. Parts B and C — web

### 6.1 Part B — tray, top-bar slot, status chip, verdicts

**Data:** `useApprovalRequestPreview(fileId)` and `useApprovalRequests(fileId)` (TanStack Query). They are invalidated by:

- `useKvReadyToShare` mark / unmark settle;
- request send, withdraw and resend;
- the dialog closing.

**Tray** (`KvReadyForClientTray`, new):

- **Placement:** a floating glass bar above `KvCanvasBottomNav`, centred, clamped by `BOTTOM_TOOLBAR_SAFE_PX`, in `FloatingSelectionBar` styling.
- **Contents:** up to 5 thumbnails plus `+n`, `{n} ready for client`, **Request approval**, and `–`.
- **When it shows:** `preview.total > 0` and the user has not tucked it for this unsent set.
- **Tucking:** on `–`, or on the next canvas pointer-down outside the tray. There is no timer.
- **Persistence:** the tucked state is kept per file in `sessionStorage`, keyed by the sorted `subject_key:version_id` set. A new mark shows the tray again.

**Top-bar slot** (`KvCanvasTopNav`, left of the avatars; also in `KvMotionEditor`'s top bar):

- **No request yet and `preview.total > 0`:** a white button **Ready for client ⑥**.
  - In `compact` it becomes a 32px icon with a count badge.
  - `compact` is also set when the chat dock or the transform panel narrows the bar.
- **Hover:** the canvas draws a frame around the set's artboards (`ObjectSelectChrome`-style overlay), or an edge pointer when the set is off screen.
- **Any request exists:** a **status chip**.
  - An open request wins: `Waiting on Dina · 0/6`. Otherwise the last result: `Approved · 6/6` or `Changes · 5/6`.
  - When there is also something new to send, the chip carries a small `+2 ready` affordance that opens the form.
- **Click (button or `+n ready`):** the request form drops down under the slot. It is the **same** `RequestApprovalPanel` the Share dialog uses, prefilled with approvers from the last request on this brand and a default message `{n} artboards ready: Craft 1 · Resize 5`.
- **Click the chip:** a popover lists every request, open first, with one row per artboard (verdict, who, when, pins). Copy link, Resend and Withdraw appear on the open request only.
  - Clicking an artboard row moves the canvas to it (switching to Resize mode if needed), selects it and opens its pins in the Comments dock.

**Verdict chips on artboards:** in the existing ready-chip slot.

- **Sketch / Craft:** `BoardChrome` at `readyChipAt`.
- **Motion:** `KvMotionTileStage` ready chip.
- **Resize:** a new small chip on the tile, which has no on-canvas chip today.
- **States:** `Waiting`, `Approved`, `Approved with fixes`, `New version asked · 5 pins`, `Feedback, no decision yet · 2 pins`. Each takes the colour of its status pill.
- **Agreement:** the chips, popover, Share dialog and client page read the same `GET v1/approval-requests`, so their counts agree.

**Analytics:** `client_lane.ready_tray_shown` (once per set), `client_lane.ready_tray_tucked`, `client_lane.status_chip_opened`, `client_lane.status_row_jumped`, plus `approval_request_form_opened{source}`.

### 6.2 Part C — Comments dock, client comments, Team only

**Data:**

- `CommentAuthor` gains `external?: boolean`. The KV comment mapper (`services/query.ts`) sets it from `author.guest || author.external`.
- `lib/client-lane/commentThreads.ts` keeps the flag too.
- api check: the agency comment serialisation must carry `guest` / `external`. It is added if missing (one presenter change plus a test).

**`CommentSidePanel`.** These are opt-in props, so the deck dock is unchanged unless the host passes them.

- **Client label:** a yellow `Client` `Label` in the anchor row, in the same slot as `Artboard deleted`.
- **Client pill:** second in the pill row, `All · Client {n} · Open · Done · @me`. It renders only while the file has client comments.
- **Team-only filter:** a `Visibility` group in the Filter dropdown with `Team only`.
- **Team-only threads:** a dashed card border and a grey `Team only` label.
- **Team-only replies:** a lock and `team only` where `edited` sits.

**Reply visibility:**

- The reply composer's `hintText` slot hosts a toggle: **Client sees this** (default on client threads) or **Team only** (lock). Team only posts `internal_only: true`.
- **New root threads from the team default to Team only** when the anchored artboard has a pending approval in an open request. Otherwise they keep today's default. The toggle is shown on root composers in that case.
- The api already hides `internal_only` comments from the lane (`Comment::scopeVisibleTo`).

**Pins:** client pins on the agency canvas keep `CommentPinOverlay`. Their avatars get a 2px yellow ring.

**Client page:** an agency reply the client has not seen is marked **New**. "Seen" is the reply ids seen per token, kept in `localStorage`.

**Analytics:** `comments.client_filter_used`, `comments.reply_visibility_toggled{to}`, `comments.team_only_thread_created`.

## 7. Part D — verification code once per device

> **Vision change, awaiting Jeff.** The vision (*Clients in frndOS*, 11 Sep) keeps codes for money, scope and sign-off. This asks for one code per device before the first KV decision. Part D ships last, so it can be dropped without touching A–C.

**Rule (KV request links only).**

- Looking, pins and comments never need a code. The name gate is unchanged.
- The **first decision** from a viewer with no active lane returns `403 verification_required`.
- After verification, every decision on that device for **30 days** is one tap, on any request and any brand the lane covers.
- Named approvers on their personal link or magic link never see a code.
- A verified guest stays **advisory** under `required`, per P0a.

**api:**

- **Table `client_verification_codes`:** `id`, `email`, `brand_id`, `share_link_id`, `code_hash` (sha256), `attempts`, `expires_at` (10 minutes), `used_at`, `created_at`.
- **`POST public/lane/code`** `{email, share_token, name?}`:
  - always returns `202`, so it is not an oracle;
  - throttled per email and per IP;
  - mails a 6-digit code (`ClientVerificationCodeMail`);
  - a new request invalidates the previous unused code for that email and link.
- **`POST public/lane/code/verify`** `{email, code, share_token}`:
  - a valid code is spent, and `{lane_code}` is returned;
  - the lane returned is the email's active **personal** lane on the brand if there is one (same as `verifyMagicLink`), otherwise a new `verified_guest` lane (30 days, existing `VERIFIED_GUEST_DAYS`);
  - a wrong code returns `422 {code: "invalid_code", attempts_left}`, and after 5 failures the code is dead (`422 {code: "code_expired"}`);
  - an expired code returns `code_expired`.
- **The gate:** in `PublicShareLinkController::decision` for `purpose = approval` links, a request with no honoured lane returns `403 verification_required`, the existing exception and code.

**web:**

- **Code sheet** (`CodeSheet`) using the Kiwi / Shop pattern:
  - six boxes with paste support;
  - an editable email, prefilled from the guest identity;
  - "Resend in 60s".
- **On success:** `POST /s/session` (existing route, new POST) sets the lane cookie, and the pending decision is re-submitted from a draft (the AC-14 magic-link pattern).
- **Summary line:** `Verified as Dina · this device, 30 days`.

**Analytics:** `client_lane.code_requested`, `client_lane.code_verified`, `client_lane.code_failed{reason}`.

## 8. Testing

**api** (Pest, scratch DB `frnd_testing` only). New test files need Daffa's permission, asked once for the list in each plan.

- **Model:**
  - KV and deck rows coexist under the new unique index;
  - two pending approvals for one `subject_key` are refused;
  - deck and plan rounds behave exactly as before (regression).
- **Request:**
  - preview eligibility, including approved-on-same-version excluded, a changed version re-entering, and `replaces`;
  - create;
  - supersede only for the same `subject_key`, while the other request stays open;
  - `nothing_ready` and `too_many_items`.
- **Roll-up:** every row of §4.3, including all-superseded giving `not_relevant`.
- **Link:**
  - `purpose = approval` is not counted against or listed among view links;
  - revoking it withdraws the request;
  - `personal_url` is null when inactive.
- **Public decision:**
  - per id, including skipped closed and replaced ids;
  - approve with pins gives `approved_with_changes`;
  - `note_required`;
  - deferred is request-level;
  - the advisory rule;
  - pins are matched per approval.
- **Digest:**
  - a newer job supersedes an older one;
  - completion sends immediately;
  - deferred sends immediately (time-travel with `Carbon::setTestNow`).
- **D:** a code's lifecycle, attempts, the non-oracle 202, the personal-lane hand-back, and the gate on KV request links only.

**web** (`bun test` per file, never a directory):

- client page: per-card decide, Approve all eligibility, the note sheet, the completion summary, the replaced state;
- Share dialog sections, the form preview, and the toggle removal;
- the tray: show, tuck and re-show on a new mark;
- the status chip and popover;
- the verdict chips;
- the comments dock: Client pill and label, the Team-only toggle posting `internal_only`, and the root default while a request is open;
- the code sheet.

Every rule gets a mutation check (break it and watch the test fail). The tsc baseline must stay at 895, with 0 errors in touched files.

## 9. Open questions for Jeff (recorded, not blocking A)

1. Board key = first generation of the chain (D-8). Is that the identity he wants?
2. Part D, one code per device, changes the vision's named-viewer rung (D-9).
3. Should deck and plan approval keep the P0a model, or move to requests later (D-2)?
4. When the request's link is revoked, is withdrawing the request the behaviour he wants? Today Withdraw is the agency verb, and the link is never listed for revoke.
5. Reply digest to the client (guide open question). Not built.

## 10. What carries over from the branch

**Kept:**

- snapshot building per item (`KvSharePayloadService::itemsFor` / `resolvePhase`);
- pins scoped by round (now per approval);
- the `ShareLinksRevoked` event and listener;
- `personal_url` and `share_link_active`;
- the magic-link copy;
- the client page building blocks (`KvPhaseGrid`, `KvFocusedItem`, `KvLinkGallery`, `PinList`, the comment threads, the advisory card, the approver hint, the dark-scope token reset);
- the redesigned `ApprovalStatusBlock` pieces;
- the frndOS `Chip` component.

**Replaced:**

- `approval_items` and the decision `item_id`;
- `kv_phases` on `POST v1/approvals` (moves to `v1/approval-requests`);
- the KV round hero's one-decision bar;
- the New-link Request-approval toggle.
