# KV Generator — fixed-price credit charging for overlay-only Resize and Motion

**Date:** 2026-09-29
**Source PRD:** [Jobs to be Done — KV Generator Credit Charging](https://fcn.sg.larksuite.com/docx/HmHwd1ryhoLJF6xYST1lAOeZg2e) (rev 43)
**Services:** `api`, `web`
**Status:** design approved, not implemented

---

## 1. Problem

KV Generator prices *how* an asset was produced, not *what* the user walks away
with. Two paths hand over a finished, placeable deliverable and charge nothing:

- **Resize of a layer-composed (PSD-import) board.** The artwork lives in
  overlays, so there is no base raster for an image model to extend.
  `KvResizeExportService::createBatch()` creates the rows already `Done` and
  never dispatches `ProcessKvResizeExportJob` — and because every KV charge
  today lives in the *completion callback* of that job, skipping the job skips
  the charge. Nothing else charges on that branch.
- **Creating a Motion project.** `KvMotionProjectController::store()` does no
  credit work at all. The video is rendered client-side at export, so no
  server-side charge point was ever introduced.

Both are silent-free. Uploading a flat PSD is currently a free workaround around
a deliverable that otherwise costs credits.

## 2. Scope

### In

| # | Change |
|---|--------|
| 1 | Layer-composed Resize charges **5 credits per newly created size** |
| 2 | Creating a Motion charges **25 credits per size**, before the project row exists |
| 3 | The Motion size picker shows the cost before the user commits |
| 4 | Both prices are admin-editable under **Admin → Financials → KV Generator Pricing**, audit-logged |
| 5 | Both charges are affordability-gated: refused up front, nothing created |

### Out

| Item | Reason |
|------|--------|
| Re-pricing AI Resize or Upscale | The PRD's own Out-of-scope section. Those paths already charge. |
| **"Flatten image + overlay" (Magic Layers) at a fixed 15** | **Deferred — see §3.1.** |
| Retroactively charging resizes or Motions created before this ships | Policy, not a build item. New actions pay; existing rows are untouched. |
| Charging a Motion export, ever | Explicitly excluded by the PRD. The charge is at create, once. |
| Volume / bundle discounts for multi-size Motion | Not requested. |

## 3. Decisions

### 3.1 Flatten-at-15 is deferred, deliberately

The PRD's Resize Pricing table asks for the "Flatten image + overlay" (Magic
Layers) path to "land on a fixed 15", while its Out-of-scope section forbids
re-pricing AI Resize. These contradict: that path is `layer_composed = false`
and is charged through the same AI job dispatch as a plain AI resize.

**Resolved: close only the free gap.** Reasons, in order of weight:

1. Charging a free path moves nobody's existing bill. Re-pricing a charged path
   does, and needs user communication and a grandfathering decision. Shipping
   them together means one rollback undoes both and support cannot attribute a
   complaint to either.
2. **Flatten is not distinguishable today.** `KvLayerDecompositionService`'s
   commit writes `metadata => ['layer_decomposition_id' => …]`
   (`KvLayerDecompositionService.php:418`) and never sets `layer_composed`, so
   `KvGeneration::isLayerComposed()` cannot separate flatten from plain AI
   resize. Pricing it apart requires *first* introducing a marker and deciding
   what happens to boards already created without one — a prerequisite feature,
   not a price change.
3. The Out-of-scope section states a reason; the "15" sits in a table whose
   neighbouring AI row is still `~`. An unfilled table is a draft.

**This deferral is a conscious partial satisfaction of the PRD's own "same
deliverable, same price" principle.** Flatten-at-live-estimate versus
overlay-at-flat-5 is still method-dependent pricing. It is recorded here so a
later reader sees a decision, not an oversight. The price store below is keyed
precisely so adding `kv_resize_flatten` later is one row and one admin field.

### 3.2 Both charges block; the UI friction differs

J3 wants a clean stop for both surfaces, while Open Questions leaves the resize
gate undecided.

**Resolved: hard server-side refusal on both. UI matched to the surface.**

- **Motion** — Cost / Balance rows and a disabled button with an explicit
  reason, in the size picker's *existing* footer. It is already a modal, so this
  is the `KvUpscaleConfirmModal` pattern at zero added friction. The charge must
  precede creation regardless.
- **Resize** — the inline `· ~N credits` already rendered at
  `KvResizePanel.tsx:462`, plus a disabled state with an inline reason. **No new
  confirm modal.** Upscale has one because it is a single expensive irreversible
  press; resize is an inline flow with no gate today, and a modal step is a UX
  regression paid for by a 5-credit charge.

The server refusal is the guarantee. The UI is courtesy, and may briefly lag.

### 3.3 Duplicating a tile is charged

`KvResizeExportService::duplicate()` clones a custom-size tile into a new,
independently editable one, entirely outside `createBatch`. Custom sizes are
only permitted on layer-composed parents (`KvResizeExportService.php:69`), so
this is a layer-composed-only path.

**Resolved: charge it at the same 5/size, same price key.** Charging only
`createBatch` would let a user pay 5 once and duplicate indefinitely — exactly
the free workaround J1 exists to close. Same deliverable, same price.

### 3.4 Motion size count is an explicit request field

The PRD states `createMotionProject` "already carries the chosen sizes". It does
not carry them as a field: the payload is `board_generation_id / name /
snapshot / timeline`, and the count lives in `snapshot.tiles[]`, which
`StoreKvMotionProjectRequest` documents as *opaque JSON — web owns the schema*
and validates only with `MaxJsonBytes`.

**Resolved: add a validated `size_count` to the POST and price from it.**
Pricing off a field the api explicitly promises not to interpret means a future
web-side snapshot refactor silently changes what users are billed. The api
cross-checks `size_count` against `count($snapshot['tiles'] ?? [])` when tiles
are present and rejects a mismatch, so the two cannot drift unnoticed.

## 4. Architecture

### 4.1 Why a new service rather than `KvCreditMeteringService`

Both new charges are **synchronous, fixed-credit and affordability-gated**.
Nothing in KV works that way. All seven existing charge sites live in
`app/Http/Controllers/Api/Internal/Kv*InternalController.php`, run *after* the
AI service completes, deduct through `deductCreditsWithDebt` (which lets a user
overdraw into debt rather than refusing), and are wrapped in
`catch (Throwable) { Log::error(...) }` so they can never fail the request.

Adding a throwing, blocking, refuse-on-shortfall method into a 567-line class
whose every member is documented as never-throws / never-blocks / debt-tolerant
inverts the contract *within* a file — where the next maintainer is most likely
to copy the wrong neighbour.

**`App\Services\Studio\KvFixedPriceChargeService`** is a new ~100-line service
beside it. The contract difference is visible at the class boundary. Each of the
two services gets a docblock naming the other and saying which to reach for.

### 4.2 `credit_prices` — keyed, admin-editable

Follows `FeatureConfiguration`'s proven shape (unique `key`, `updated_by`,
fail-open read) with an integer value instead of a boolean.

```
credit_prices
  id          ulid, pk
  key         string, unique
  credits     integer, >= 0
  updated_by  foreignUlid, nullable
  timestamps
```

Seeded keys:

| Key | Default | Unit |
|-----|---------|------|
| `kv_resize_overlay_only` | 5 | credits per size |
| `kv_motion_create` | 25 | credits per size |

Keyed rows rather than named columns is what makes the §3.1 deferral cheap: a
future `kv_resize_flatten` is one insert, not a migration.

`CreditPrice::credits(string $key): int` reads the row and **falls back to a
code default constant** when the row is missing or unreadable — never to 0. A
database blip must not silently make a paid feature free. `0` remains a valid
*stored* value meaning "this action is free", per the PRD.

**No cache on the charge path.** `FeatureConfiguration` caches because it is
read on every request; a price is read once per user action, so a lookup against
a two-row table is free. Reading live is what makes J4 true: the charge is
always the current price, and there is no TTL during which a saved price is not
yet in force.

### 4.3 `InsufficientCreditsException`

`CreditService::deductCredits()` already enforces the balance, but throws a bare
`\Exception('User does not have enough credits.')` — indistinguishable from any
other failure, so web cannot render J3's clear message.

A typed `App\Exceptions\InsufficientCreditsException` carries `required` and
`available`, and renders to **the same 400 wire shape the credit middleware
already emits** (`CheckUserCredits` → `errorJsonResponse('Insufficient user
credits' | 'Insufficient workspace credits', …, 400)`). One wire contract, not
two — web keeps a single shape to recognise.

The pre-flight check uses the existing `CreditService::hasSpendableCredits()`,
which is Extra-Credit-aware and already backs the `check.credits` middleware.
The existing middleware itself is **not** reusable here: it takes a *static*
route argument (`check.credits:1`) and both new costs are dynamic.

**Gate with `hasSpendableCredits()`, but fund with `deductCreditsWithDebt()` —
not `deductCredits()`.** This pairing is deliberate and the two halves are not
interchangeable:

- `hasSpendableCredits()` counts the workspace pool **plus eligible Extra
  Credit**. `deductCredits()` does not draw Extra Credit at all — it refuses
  whenever the pool alone is short. Pairing them would let a workspace pass the
  gate on its Extra Credit and then be thrown out by the deduction, refusing a
  user who can in fact pay. That is a wrong refusal, not merely an inelegant one.
- `deductCreditsWithDebt()` funds from pool then Extra Credit exactly as every
  other KV charge does, and returns `extra_credit_drawn` so the `CostHistory`
  row can carry `is_from_extra_credit` with the same meaning it has everywhere
  else.

The refusal therefore comes from the **pre-check**, not from the deduction. The
deduction stays debt-tolerant, so the only way to reach debt on this path is a
concurrent spend landing between the check and the deduction — the same
narrow race every other charge in the system already accepts.

### 4.4 Endpoints

| Method | Route | Auth | Purpose |
|--------|-------|------|---------|
| `GET` | `v1/studio/kv/pricing` | authenticated | Both prices, for the estimate. Keeps every number out of web source. |
| `GET` | `v1/admin/credit-prices` | `superadmin` | Admin list |
| `PATCH` | `v1/admin/credit-prices/{key}` | `superadmin` | Admin edit, audit-logged |

Admin routes join the existing
`Route::prefix('admin')->middleware(['auth:api','scope_role:internal','superadmin'])`
group in `routes/api.php` (~line 6173), beside `feature-configurations`.

Writes go through `AuditLogService::log()` with `before_state` / `after_state`,
the pattern already used at `AdminModelSettingController.php:127`. This
satisfies "who changed it, old value → new value, and when" against the existing
Audit Log that `/admin/audit-log` already renders. Note that
`FeatureConfigurationController` only writes `Log::info` — it is the structural
model to copy, **not** the audit model.

### 4.5 Charge points

| Site | File | Rule |
|------|------|------|
| Layer-composed resize batch | `KvResizeExportService::createBatch()` (`:52` branch) | Charge `kv_resize_overlay_only` × the number of rows where `wasRecentlyCreated` is true |
| Tile duplicate | `KvResizeExportService::duplicate()` | Charge `kv_resize_overlay_only` × 1 |
| Motion create | `KvMotionProjectController::store()` | Charge `kv_motion_create` × `size_count`, **before** `KvMotionProject::create()` |

**`wasRecentlyCreated` is load-bearing.** `createBatch` uses `firstOrCreate`
keyed on `(parent_generation_id, platform_id)`. Charging per *requested*
platform id would re-bill every repeat request for sizes that already exist.
The affordability pre-check must therefore also be computed against the count of
rows that will actually be new, not the count requested — otherwise a user with
5 credits is refused a request for three sizes of which two already exist.

**Ordering.** The *affordability check* precedes any write in every case; where
the deduction itself falls differs, and the difference is forced by the code:

- **Motion** — pre-check affordability, then in one transaction insert the
  project, deduct, and write `CostHistory`. Insert-before-deduct rather than
  deduct-before-insert so the charge has a stable, row-derived idempotency key
  (see below); the transaction gives the identical guarantee, since a failed
  deduction rolls the project back and the user is left exactly as they started.
- **`createBatch`** — which rows are new is only knowable *after* `firstOrCreate`
  runs, so the order is: count the platform ids that do not yet exist, check
  affordability against that count, create, then deduct for the rows that came
  back `wasRecentlyCreated`. All inside one transaction, same rollback property.

Both sites therefore share one shape: **check → transaction { write, deduct,
audit } → rollback on shortfall.** The pre-check is what produces the clean
refusal; the transaction is what makes it true under a race.

The pre-count and the post-count can differ under a concurrent request for the
same sizes; the transaction and `firstOrCreate`'s unique key make the loser a
no-op rather than a double charge.

**A zero price must short-circuit.** The PRD allows `0` to mean "this action is
free", but `CreditService::hasSpendableCredits()` applies `max(1, $cost)` — so
passing a computed cost of 0 would demand 1 credit and refuse a broke user a
free action. When the resolved total is 0, skip the affordability check, the
deduction and the `CostHistory` row entirely.

**Idempotency.** Each charge writes a `CostHistory` row whose
`batch_identifier` is derived from the row it pays for, matching the readable
convention every other KV charge uses (`kv_upscale_{ulid}`,
`kv_resize_{ulid}_{run}`):

- `kv_resize_overlay_{$export->id}` — one per created export row, from both
  `createBatch` and `duplicate()`, so the same row can never be billed twice.
- `kv_motion_create_{$project->id}` — which is why the project is inserted
  inside the transaction before the deduction rather than after it.

A UUID is **not** required. `batch_identifier` was uuid-typed on
`cost_histories` and `user_workspace_chat_debts`, and a non-uuid string there
used to drop the charge silently; both were relaxed to varchar
(`2026_04_30_000002_…` and `2026_08_22_100000_relax_chat_debt_batch_identifier_to_string`).
Row-derived string ids are now the house style and are what these charges use.

Note this idempotency key only guards the `CostHistory` write. The refusal comes
from the **pre-check** (§4.3), not from the deduction: the deduction is
`deductCreditsWithDebt`, so a concurrent spend landing between the check and the
deduction can still write a debt row. That narrow race is the same one every
other charge in the system accepts.

`cost_type` values follow the existing `kv_*` convention
(`kv_resize_export`, `kv_generation_upscale`, …):

- `kv_resize_overlay_only`
- `kv_motion_create`

`chat_features` stays `'KV Generator'`, matching every other KV row.

`amount` (the platform's USD cost) is `0.0`. Every other KV row derives it from
a vendor invoice, but these two actions make no vendor call at all — that is
precisely why they were free. Recording 0 is accurate.

**Correction to an earlier draft of this section:** admin margin analysis does
NOT read `amount`. `AdminRevenueController::costsSummary` and
`AdminMetricsService::consumedCredits()` both derive platform cost from
`SUM(actual_credit)`; `amount` is summed nowhere. So these zero-vendor-cost rows
will *inflate* `total_cost_idr` and *understate* `margin_percent` rather than
showing as pure margin. Nothing breaks, but the two new `cost_type`s should be
excluded from the cost side of margin reporting. Tracked as open item 3 below.
`prompt_tokens` / `completion_tokens` / `total_tokens` are 0 for the same
reason, matching the flat-rate camera-angle path.

### 4.6 Web

| Piece | Location |
|-------|----------|
| `useKvFixedPricing()` | new hook over `GET v1/studio/kv/pricing`, short `staleTime` |
| Motion cost + gate | `KvMotionSizePicker.tsx` footer — button already reads `Create motion · N sizes` (`:326`); extend to `· N credits` and add Cost/Balance rows + disabled state |
| Resize cost + gate | `KvResizePanel.tsx:462` — already renders `· ~N credits`; add the overlay-only price path and the disabled state |
| Affordability | existing `useEffectiveCredits()` → `canSpend(cost)` |
| Admin page | `src/app/admin/financials/kv-generator-pricing/`, sibling of `extra-credit` and `subscription-plans`; add to `AdminSidebar.tsx` |

No price constant is written in web. The resize estimate today reads
`estimated_credits` off `/image-models` via `useGptImageCreditEstimate` — that
model-priced path is untouched; the overlay-only branch reads the new endpoint
instead.

## 5. Data flow

```
Admin edits price
  PATCH v1/admin/credit-prices/kv_motion_create { credits: 30 }
    → CreditPrice::set(key, credits, updated_by)
    → AuditLogService::log(before_state, after_state)

User opens Motion size picker
  GET v1/studio/kv/pricing → { kv_motion_create: 30, kv_resize_overlay_only: 5 }
    → button: "Create motion · 3 sizes · 90 credits"
    → canSpend(90) false → disabled + "Not enough credits"

User presses Create motion
  POST .../motion-projects { …, size_count: 3 }
    → size_count cross-checked against snapshot.tiles
    → CreditPrice::credits('kv_motion_create') × 3        (read live)
    → hasSpendableCredits? no  → 400 "Insufficient user credits", nothing created
    → yes → transaction { KvMotionProject::create; deductCreditsWithDebt; CostHistory }
    → 201

User exports the Motion, now or next month
  → no charge, ever
```

## 6. Testing

**api**

- `credit_prices` read falls back to the code default when the row is absent and
  when the query throws — never to 0.
- `createBatch` on a layer-composed parent charges once per new row; a repeated
  request for the same platform ids charges nothing.
- `createBatch` refuses when the balance cannot cover the *new* rows, and
  creates nothing.
- `duplicate()` charges exactly one size.
- `createBatch` on a non-layer-composed parent charges nothing new (AI path
  unchanged).
- A price of `0` lets the action through for a user with zero credits, and
  writes no `CostHistory` row.
- Charging the same export row twice writes one `CostHistory` row, not two.
- A workspace whose pool is short but whose Extra Credit covers the cost is
  **allowed through and funded from Extra Credit**, with
  `is_from_extra_credit` true on the `CostHistory` row. This is the pairing
  in §4.3 and the single most likely thing to regress.
- `amount` on the `CostHistory` row is `0.0`.
- Motion `store()` with `size_count: 3` deducts `3 × price`, and with an
  insufficient balance returns 400 and writes no `KvMotionProject` row.
- `size_count` that disagrees with `snapshot.tiles` is rejected.
- A price change is reflected by the very next charge — no stale read.
- `PATCH` writes an `AuditLog` row with both states; a non-superadmin is refused.
- `CostHistory.batch_identifier` is a UUID.

Run the api suite with scratch Postgres and explicit test paths — SQLite cannot
migrate this schema, and `--filter` does not dodge the broken suite loader.

**web**

- The Motion button label reflects size count × the fetched price, and is
  disabled with a reason when `canSpend` is false.
- Zero price renders as free rather than "0 credits".
- A 400 insufficient-credits response surfaces the message and leaves the picker
  open.
- The admin form rejects negatives and non-integers.

Run with `bun test`. There is no type gate; diff `tsc` against a baseline
worktree rather than trusting a clean build.

## 7. Risks

| Risk | Mitigation |
|------|-----------|
| A charge is written twice for the same row | Keys are derived from a freshly created row's ULID, so they cannot collide across requests. Note `cost_histories.batch_identifier` carries only a PLAIN btree index, **not** a unique constraint — verified against the live schema — so the `exists()` check in `charge()` is best-effort, not race-safe. Any future retry/replay caller that reuses a batch id needs a partial unique index first. |
| Quote shown ≠ amount charged after an admin edit mid-session | Server is authoritative and reads live. Worst case is a stale *quote* bounded by the hook's `staleTime`, never an inconsistent charge. The PRD's "already in progress keeps the price it started with" is satisfied: the action starts at the button press, which is the charge moment. |
| Double-charging through `firstOrCreate` | Charge keyed on `wasRecentlyCreated`, with an explicit test. |
| A price row missing makes a paid feature free | Read falls back to the code default, never 0. |
| Users surprised by a newly-charged path | Out of engineering scope, but flagged: the PRD's own open question about existing in-app or marketing copy promising these are free is **unanswered** and needs an owner before launch. |
| `KvMotionSizePicker.tsx:120` comment states the custom-size tier "costs no credit" | Still true of the custom-size *row*, but the surrounding flow now charges. Update the comment in the same change. |

## 8. Corrections to the PRD

Recorded so the doc can be amended:

- `layer_composed` is read at `KvResizeExportService.php:52`, not `:49`.
- `createMotionProject` does **not** carry the chosen sizes as a field — see §3.4.
- The PRD's "Flatten image + overlay" row and its Out-of-scope section
  contradict each other — resolved in §3.1.
- J3 and the Open Questions table disagree on whether resize blocks — resolved
  in §3.2.
- The PRD does not mention `KvResizeExportService::duplicate()`, a second
  layer-composed size-producing path — resolved in §3.3.
- The PRD's price-per-size for Motion was listed as an unanswered open question
  in one section and as 25 in another; confirmed as **25 per size**.

## 9. Open, needs an owner

1. In-app or marketing copy promising Motion or layer-composed resize is free —
   must be found and updated alongside the charge.
2. The pre-existing estimate-vs-charged gap on AI Resize, which the PRD itself
   flags as possibly a standing bug. Untouched by this work.
3. Margin reporting counts these zero-vendor-cost charges as platform cost (see
   §4.5). Excluding `kv_resize_overlay_only` and `kv_motion_create` from the
   cost side is a small admin-side change, out of scope here.
4. **Product decision, unresolved:** removing a layer-composed size and re-adding
   it charges again. `KvResizeExportController::destroy` hard-deletes, so the
   re-add is a genuinely new row. This is consistent with AI resize (where a
   re-add really does re-run the model) but for a deterministic projection the
   user pays twice for byte-identical output, reachable in two clicks from the
   shipped remove-tile control. Either accept it and warn in the UI before the
   delete, or key the charge on `(parent_generation_id, platform_id)` rather
   than row identity.
