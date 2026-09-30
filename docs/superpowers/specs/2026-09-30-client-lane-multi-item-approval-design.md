---
title: Client Lane — multi-item approval rounds
slug: client-lane-multi-item-approval
author: daffa
created: 2026-09-30
status: draft (design approved in chat 2026-09-30, spec awaiting review)
services: [api, web]
parent: client-lane-p0a (api#539, web#705 — merged 2026-09-29)
---

# Client Lane — multi-item approval rounds

## 1. Problem

P0a freezes exactly **one** item per approval round (`approvals.subject_version_type`
+ `subject_version_id`). For a key visual that is wrong in practice: an agency
sends the hero board *and* its sizes, and a client wants to review them on one
page, the way the regular KV share link already shows them (stage tabs, grid).

Two defects in the current single-item KV round make this worse and are fixed on
the way:

- **The KV approval page is not frozen.** `PublicShareLinkController::document()`
  builds KV from `KvSharePayloadService::build()`, which resolves "whatever is
  marked ready now" on every call. An item edited or unmarked after the request
  changes or disappears on the client's page.
- **The frozen id drifts from the rendered id.** The payload swaps a board for
  its chain *tip* (`KvSnapshotService::resolvePublicBoards`) and a motion clip for
  the *newest* export of its (project, ratio); resize rows are overwritten in
  place. Web matches the round to a payload item by exact id
  (`kvTarget.ts::findKvTarget`), so after an iteration the target can vanish.

## 2. Goals / non-goals

**Goals**

- One approval round can hold N items (KV boards, resize tiles, motion clips).
- The agency picks **stages** in the same New-link form as a view link (toggle on).
- The client sees the frozen set with stage tabs, pins on **any** item, and makes
  **one decision for the whole set** (Phase 1).
- The data model supports **per-item decisions** later without a migration
  (Phase 2 = UI only).
- KV approvals become truly frozen (snapshot per item).

**Non-goals (this spec)**

- Per-item decision UI (Phase 2).
- Multi-item rounds for decks (per slide) or plans — the model allows it; nothing
  ships.
- Deck/plan share sheets adopting the unified New-link toggle (separate change).
- "Decision due" date + reminders (P0b PRD; needs `approvals.due_at`).
- Removing `approvals.subject_version_*` (later cleanup).

## 3. Decisions (agreed in chat, 2026-09-30)

| Question | Decision | Why |
|---|---|---|
| What does the client decide on? | Model per item; Phase 1 UI = one decision for the set | Proofing-tool practice (Ziflow, Filestage, Frame.io): decisions attach to assets, a round groups them. UI can grow to per-item with no migration. Same UX as deck approval today (one decision, pins per slide). |
| How does the agency choose items? | Stage multi-select, same control as the view link | "Like a normal share link"; one form, two modes. |
| Frozen or live? | Frozen: `snapshot` jsonb per item | "You approved v1, this is v2" must stay answerable; mirrors `DeckVersion.document`. |
| Which id is frozen? | The id the page **renders** (tip board / newest motion / resize row) | Removes the id-drift defect. |
| Cap | 50 items per round | Guard against mass-resize files; fits a phone gallery. |

## 4. Data model (api)

### 4.1 New table `approval_items`

| column | type | notes |
|---|---|---|
| `id` | ulid PK | |
| `approval_id` | ulid FK → approvals, cascade delete | |
| `position` | smallint | display order: phase order (sketch, craft, resize, motion), then payload order |
| `phase` | string(16) | `sketch` \| `craft` \| `resize` \| `motion` \| `deck` \| `plan` |
| `version_type` | string(32) | `kv_generation` \| `kv_resize_export` \| `kv_motion_export` \| `deck_version` \| `fingerprint` |
| `version_id` | string(64) | the rendered id (see §3) |
| `label` | string(160) | e.g. `Craft · Hero board`, `Resize · IG Story · 1080×1920` |
| `snapshot` | jsonb, nullable | the payload item as rendered at request time (`image_url`, `overlays`, dimensions, `video_url`, …). `null` for deck/plan (deck document lives in `deck_versions`) and for backfilled rounds |
| `status` | string(32) | `pending` \| `approved` \| `approved_with_changes` \| `changes_required` \| `not_relevant` (CHECK) |
| `created_at` | timestampTz | immutable row except `status` |

Indexes: `(approval_id, position)` unique; `(version_id)` for pin validation.

Snapshot URLs are permanent public S3 URLs with a fresh key per render
(verified: `…/kv-resize-exports/{file}/{uuid}.png`), so an overwritten resize
tile does not change a snapshot. Risk: a hard-deleted S3 object breaks an old
snapshot image — acceptable; the page shows the existing broken-image fallback.

### 4.2 `approval_decisions.approval_item_id`

Nullable ulid FK → `approval_items`, null on delete.

- `null` — a decision on the **whole round** (Phase 1 always sends this).
- set — a decision on **one item** (Phase 2).

### 4.3 Status semantics

- Item status: a round-level resolving decision sets **every** item; an item-level
  resolving decision sets that item.
- Round status (`approvals.status`) stays the source of truth for gates
  (`canLaunch`, `can_decide`). Phase 1: set exactly as today by `resolve()`, then
  copied onto items. Phase 2 (defined now, built later): the round resolves when
  every item is resolved; any `changes_required` item ⇒ round `changes_required`;
  otherwise `approved_with_changes` if any item is, else `approved`.
- Policy (`none | optional | required`), named approvers, advisory guests and
  deferral stay **round-level** — unchanged.

### 4.4 Compatibility

- `approvals.subject_version_type/id` are kept and written with the **first** item.
- Deck and plan rounds: one item each; behaviour unchanged.

## 5. API changes

### 5.1 Request — `POST v1/approvals` (C-9, additive)

- New `kv_phases: string[]` (`in:sketch,craft,resize,motion`, min 1) for `kv_file`.
- `kv_ready_item_id` still accepted (becomes a one-item set, phase derived as today).
  Exactly one of the two is required for `kv_file`; both prohibited otherwise.
- `422 {code: "nothing_ready"}` when the selected phases hold no ready item.
- `422 {code: "too_many_items", max: 50}` above the cap.

`ApprovalService::request()`:

1. Before the transaction / row lock: resolve items. Extract the per-phase item
   resolution out of `KvSharePayloadService::build()` into
   `itemsFor(StudioFile $file, array $phases): array` (build() calls it — no
   behaviour change for view links). Map each payload item to
   `{phase, version_type, version_id, label, snapshot}`.
2. In the transaction: insert the round (subject_version_* = first item), insert
   `approval_items`, mint/reuse the `comment` link with its phases = union of the
   link's phases and the selected ones (today's `reuseOrMintCommentLink`, now with
   a phase list).
3. `freezeVersion()` returns a list of items; deck (`freezeDeckVersion`) and plan
   (`fingerprintPlan`) return a one-element list.

### 5.2 Public read — `GET public/share-links/{token}` (C-1, additive)

- New `items: [{id, phase, label, version_id, status, snapshot}]` for a link with a
  round (empty for a `view` link).
- `version` unchanged in shape: label `v{round}`, id = first item's `version_id`.
- KV `document` for a round **with snapshots** is built from them, same shape as
  `PublicKvResponse` (`{name, brand_slug, phases: [{phase, items[]}]}`); rounds
  without snapshots (backfilled) and `view` links keep the live payload.
- `can_decide` unchanged (round-level).

### 5.3 Comments + pins (C-4, C-5)

- `comments()`: root filter `split_part(anchor->>'id', ':', 2) IN (round item version_ids)`
  (replaces the single `= subject_version_id`).
- `storeComment()`: a new root's anchor version must be one of the round's item
  `version_id`s, else `422 invalid_anchor` (message: "That element is not in this
  round.").
- `ApprovalService::validatePins()`: same membership rule.
- **Pins belong to their round** (decision 2026-09-30): both `comments()` and
  `validatePins()` also require the root pin's `created_at >= approvals.created_at`.
  A resize tile keeps its row id across rounds, so version membership alone would
  carry round-1 pins onto the regenerated tile in round 2. Earlier-round pins stay
  visible to the agency in the editor.
- Anchor format unchanged: `{phase}:{item.version_id}:{part}`. Resize part = the
  tile **row id** (`tile.{row_id}`), matching the editor's tile keying (fixes the
  existing `platform_id` vs row-id mismatch for approval pins).

### 5.4 Decision — `POST public/share-links/{token}/decision` (C-3, additive)

- Optional `item_id` (ulid, must belong to the current round). Phase 1 web never
  sends it. When present: decision row gets `approval_item_id`, item status set,
  round resolved per §4.3 Phase 2 rule (implemented + tested now, UI later).

### 5.5 Agency list — `GET v1/approvals` (C-9, additive)

- Each round gains `items: [{id, phase, label, version_id, status, thumbnail_url}]`
  (`thumbnail_url` from the snapshot's image; null for deck/plan).
- `decisions[]` gain `item_id` (null in Phase 1).

### 5.6 Notifications + mail

- `ApprovalNotifier::versionLabel()`: `v{round}` for one item, `v{round} · {n} items`
  for more. Flows into both mails' subjects/headers and the inbox target label.
- `ApprovalDecidedMail` shows the total pin count.

## 6. Web changes

### 6.1 Agency form (KV share sheet)

Builds on `develop 6ed9386e8` (unified New-link form with the Request-approval
toggle).

- Toggle ON keeps **"Select stages to include"** (same `PillTabs` block, counts,
  disabled-when-unmarked rules). Toggle ON swaps only Expiry/Label/Passcode for
  Approvers/What changed, and "Create link" for "Send for approval".
- `ApprovalFields` drops the single-item picker (`kvChoices`, "Which item needs a
  decision?"); `useApprovalRequestForm` takes `kvPhases` and posts `kv_phases`.
  `readyChoices` in `KvSharePanel` goes away.
- `CreateApprovalInput` gains `kv_phases?: string[]`.

### 6.2 Public page `/s/{token}` (KV round)

- Header: `{title} · v{round} · {n} items` (+ "Needs your decision").
- **Gallery**: stage tabs + grid, the same visual as the view-link share page
  (screenshot 2 of the 2026-09-30 discussion); each card shows its pin count badge.
- **Focused view**: tap a card → the item large with `PinLayer` (pins on any
  item), ←/→ and swipe between items, caption `Phase · label`. A one-item round
  opens straight into the focused view (today's look).
- Desktop: gallery/focused view left, existing sidebar right (What changed,
  Approvers, decision bar). Mobile: grid → full-screen focused view, decision bar
  sticky.
- Pins: numbered 1…n **per round across items**; `PinList` grouped by item
  ("Resize · IG Story — 2 pins"). `pinsFromComments` filters by the round's
  version-id set.
- Decision bar: "Approve all {n}" (n > 1) / "Approve v{round}" (n = 1), "Request
  changes", "I need more time". Terminal banner: "Approved by {name} on v{round} ·
  {n} items".
- `kvTarget.ts` is replaced by an items-based model (`items[]` from C-1);
  `KvHero` renders gallery + focused view instead of target + "Also shared".
- OG image: first item's snapshot image + "{n} items · Needs your decision".
- Deck/plan pages read `items[0]`; no visual change.

### 6.3 Editor (agency)

- `ApprovalStatusBlock`: "Approval · round {r} · {n} items"; decision rows show
  pin counts.
- `kvAnchorLabel` (`lib/studio/kv/kvCommentAdapter.ts`): a pin whose version is an
  approval item reads "on v{round}" via a `versionLabelById` map built from
  `GET v1/approvals` (same pattern as `deckPinVersionBadge`), instead of "older
  version".
- Board pins already render on the canvas (tip id is in the chain); resize pins
  land on the tile by row id; motion pins appear in the comment panel only.

## 7. Analytics (`client_lane.*`)

- `approval_requested` + `item_count`, `phases`.
- `decision_submitted` + `item_count`.
- `pin_placed` + `phase`.
- `gallery_item_opened {phase, index}` (new) — whether clients actually browse the set.
- Taxonomy rows (Lark "frndOS Event Taxonomy") for all changed/new events.

## 8. Migrations + compatibility

1. `create_approval_items_table`.
2. `add_approval_item_id_to_approval_decisions`.
3. `backfill_approval_items`: one item per existing round from
   `subject_version_*` (phase derived from version type; label `v{round}`;
   `snapshot` null; status copied from the round). Reversible (`down()` deletes
   only backfilled rows — marked by `snapshot IS NULL AND created_at = approvals.created_at`).
4. Run with `TELESCOPE_ENABLED=false` (lesson: data migrations OOM under Telescope).

Contract process: the first commit on each branch updates the **"Contract
(frozen)" section in both service PRDs** (`api/docs/prd/client-lane-p0a/api.md`,
`web/docs/prd/client-lane-p0a/web.md`) — additive only — and Jeff reviews it.

## 9. Testing

**api (Pest, scratch Postgres — never the dev DB; see lesson on test DB isolation)**

- `ApprovalService`: multi-item freeze + snapshots; rendered-id freezing (tip
  board, newest motion, resize row); `nothing_ready`; `too_many_items`;
  `kv_ready_item_id` back-compat; round decision sets all items; item decision
  sets item + aggregate (all four aggregate outcomes); pins on any item accepted,
  outside the round rejected; round 2 supersedes.
- `PublicShareLinkController`: `items[]` shape; KV `document` from snapshots
  (unchanged after the live board is edited/unmarked); comments across items;
  anchor validation; byte-identical 404s kept.
- Migration: backfill produces one item per round; down() round-trips.

**web (`bun test`, `within(document.body)`, spy `axiosInstance` — no new `vi.mock` of shared modules)**

- `KvSharePanel`: toggle ON keeps stages; posts `kv_phases`.
- `DecisionPage` (KV, 3 items): tabs, focused view, pin on item 2 posts the right
  anchor, "Approve all 3" posts a round-level decision, pin numbering across items.
- `pins.ts`: filter by version set, numbering.
- Mutation-test each new test (lesson: plan-dictated tests are vacuous until run).

**Manual**

- P0a smoke script extended: 1 craft board + 3 resize tiles, from a phone and a
  laptop; edit a board after the request and confirm the client page is unchanged.
- Visual check of KV/deck/plan sheets and `/s/*` in Midnight, Aurora, Daylight.

## 10. Delivery

- Branches: `feature/daffa/vc-client-lane-multi-item` in api and web, cut from
  `develop` (web includes `6ed9386e8`).
- Order: api (migrations → service → controllers/presenter → tests) → web.
- Flag: agency side stays behind `show-client-lane`; the public page handles both
  shapes, so api can deploy first.

## 11. Open questions

- Jeff's review of the additive contract changes (C-1, C-3, C-4/5, C-9).
- 50-item cap — revisit with real files once used.
- Should a round's items be editable before the client's first decision (add a
  forgotten size without a new round)? Out of scope; the model allows it.
