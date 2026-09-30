# Client Lane Multi-Item Approval — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An approval round on a KV file freezes N items picked by stage (same New-link form as a view link, toggle on), and the client reviews them on `/s/{token}` as stage tabs + grid → focused view with pins on any item, then makes one decision for the whole set.

**Architecture:** The agency form keeps its stage `PillTabs` in approval mode and posts `kv_phases`. The public page reads C-1's new top-level `items[]` through one pure model (`kv/roundItems.ts` → `KvRoundItem[]`, replacing `kvTarget.ts`); pins are filtered by the round's version-id set and numbered round-wide; `KvHero` becomes a dispatcher between the unchanged view-link gallery (`KvLinkGallery`) and the new round hero (`KvRoundHero` = `KvPhaseGrid` + `KvFocusedItem`). `DecisionPage` only swaps its single-target wiring for the items model, copy helpers (`lib/client-lane/round.ts`) and a controlled `focusedItemId`. The editor labels client pins "on v{round}" through a `versionLabelById` map built from `GET v1/approvals`.

**Tech Stack:** Next.js 16 app router, React 19, TypeScript, Tailwind 3.4, TanStack Query v5, PostHog (`posthog-js`), `bun test` (vitest-compatible API, jsdom preload), Testing Library.

**Spec:** docs/superpowers/specs/2026-09-30-client-lane-multi-item-approval-design.md

## Contract deviations

- **D-1 — RESOLVED 2026-09-30 (orchestrator):** the api plan (Task 7, `ApprovalPresenter::agencyItems`) now emits `version_id` on every C-9 list item and the spec §5.5 + api PRD note say so; web keeps the field optional only so an older api still degrades gracefully. Original note: spec §6.3 wants the editor's `kvAnchorLabel` to read "on v{round}" via a `versionLabelById` map built from `GET v1/approvals`, but the agreed C-9 list item shape is `{id, phase, label, status, thumbnail_url}` — **no `version_id`**, and the current round's approval carries no version at all. Without it web cannot map a pin's version to a round. Request: add `"version_id"` to each C-9 list item. Web types it optional (`AgencyApprovalItem.version_id?`) and degrades: earlier rounds' `rounds[].version.id` (first item only) still label, everything else keeps reading "older version". Task 0 raises it; Task 8 implements against the optional field.
- **A-1 (assumption, no change requested):** `POST v1/approvals` 201 `approval` uses the same presenter as `GET v1/approvals`, so it carries `items[]`. `client_lane.approval_requested.item_count` reads `created.approval.items.length`; if absent it falls back to `1`.
- **Not a contract item, but a deliberate departure from the brief:** the public `/s/*` page keeps its documented hand-rolled styling (`src/components/client-lane/ui.ts:1-8`, dark-scoped by `data-theme-scope="dark"` at `DecisionPage.tsx:574-580`) instead of frndOS v2 components/tokens — it is the unauthenticated guest surface and must not re-skin under a viewer's theme. New public components follow `ui.ts`. The frndOS/tri-mode rules apply to the agency surfaces (KvSharePanel, RequestApprovalPanel, ApprovalStatusBlock), which only reuse existing v1/v2 controls here.

## Global Constraints

- **Where to work:** a git worktree, so HMR never touches Daffa's running dev server on `:3000`: `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item` on branch `feature/daffa/vc-client-lane-multi-item` cut from local `develop` (must contain `6ed9386e8` and `7d3091fad`). `.worktrees/` is gitignored. A web worktree needs its own `bun install` **and** a copied `.env.local` (else the app never calls the api). Every command below `cd`s into that literal path — agent shells reset cwd between calls, never rely on a shell variable.
- **Commits:** `<type>(web): …`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit on the feature branch; **never push** (Daffa pushes manually). Never `git stash` (a popped stale stash corrupted files once).
- **Tests:** `bun test <file>` — one file per invocation; never `bun test <directory>` (a directory run once ate 26 GB). Never `bunx vitest`. Query with `within(document.body)`, never `screen`. No `vi.hoisted` (bun skips the file). Keep every test file < ~45 KB (past ~51 KB bun reports a bogus SCSS parse error naming `base.module.scss`). `KvSharePanel.test.tsx` is 29.7 KB today and ends ≈36 KB after Task 2.
- **Mocks:** bun's `vi.mock` registry is process-global, first registration wins. Register **no new `vi.mock`** of any shared module. Network edges are spied: `vi.spyOn(axiosInstance, "get"|"post")` (agency), `vi.spyOn(axiosPublic, "get"|"post")` (public), `vi.spyOn(globalThis, "fetch")` (`/s/session`), analytics via `vi.spyOn(posthog, "capture")` with `import posthog from "posthog-js"` (verified working under bun on 2026-09-30). The only existing module mocks we touch are inside `KvSharePanel.test.tsx`; keep their factory shapes byte-identical (`@/lib/featureFlags` stays `{ useClientLaneEnabled: () => clientLaneOn }`). Known pre-existing collision, not ours: running `KvSharePanel.test` + `SharePlanDialog.test` + `KvOpenInStudioCard.test` in ONE process blanks KvSharePanel with `useChatStore.subscribe is not a function` — identical at HEAD. Run suites individually.
- **Controlled harnesses:** a component that takes `focusedId`/`onFocusChange` is tested through a `useState` harness — a stubbed callback makes every focus assertion vacuous.
- **Mutation check is mandatory:** after each new test passes, break the behaviour it guards (the step names exactly what to break), confirm the test FAILS, restore, confirm PASS. Tests written from reasoning are often vacuous. Derive exact expected strings/numbers by running the code (print them) when a step's expectation disagrees with reality — then fix the expectation only if the code matches the spec; otherwise fix the code.
- **Type gate:** there is no CI type gate and `bunx tsc --noEmit -p .` has a baseline of ~913 errors. Required: **zero** tsc errors in files this plan touches (except `KvGeneratorLayout.tsx`, which must not rise above its Task 0 baseline count). `bunx eslint <touched files>` clean; `bunx prettier --write <touched files>` before each commit. `bun run build` is broken locally — only if a build is needed: `node node_modules/next/dist/bin/next build`.
- **Agency UI:** frndOS components only, v2 first, v1 fallback; `KvSharePanel.tsx` is v1-only by design (its header comment, lines 18-20) — do not introduce v2 there. v2 `SelectMenu` cannot be used inside `BaseModal`/the share dialog (portals at z-70 under the modal's z-71). Design tokens (`text-text-inverse-*`, `text-textXs…`), no new dark hex / `bg-[rgba(26,26,26,…)]`; the change must read right in Midnight, Aurora and Daylight.
- **Public side analytics are PII-free:** no names, emails, tokens, lane codes — `subject_type`, phases, counts, booleans only.
- **Flag:** agency side stays behind `show-client-lane` (`useClientLaneEnabled`); `/s/*` is unflagged and must render BOTH C-1 shapes (with and without `items`) because the api deploys first.
- **No new routes** (the `mobile-route-access` allowlist already admits `/s`).

## Review Focus

Five input classes most likely to hurt a user that the happy-path tests would not catch. Each has a named test in its owning task.

1. **Arrow keys while typing.** ←/→ in the pin-note textarea, the name gate, or any field must not change the focused item (and the note must not jump to another artwork). → Task 5 "ignores arrow keys typed into a field" + "ignores arrow keys while keyboard stepping is off"; Task 6 "keeps ←/→ inside the pin note instead of changing item".
2. **Round-wide pin numbering vs per-item drawing.** A new pin on item 3 after two pins on items 1 and 2 must be announced and drawn as **3**, not **1** (PinLayer used `pins.length + 1` of the filtered list). → Task 4 "numbers the draft marker from draftNumber"; Task 5 "draws only this item's pins and numbers a new draft after the whole round"; Task 6 "numbers a new pin after every pin in the round".
3. **Selecting a listed pin that sits on another item.** Tapping a `PinList` row must bring its item into the focused view with the marker active, not highlight an invisible marker. → Task 6 "jumps to the item a listed pin sits on".
4. **Every C-1 shape the page can receive.** View link (`items: []`), one-item round, backfilled round (`snapshot: null`) whose live item exists or vanished, and a response with no `items` key at all (api mid-deploy). None may crash; decidable rounds stay decidable. → Task 1 `approvalItemsOf` / `roundVersionIds` tests; Task 3 `kvRoundItems` fallback/skip tests; Task 6 "opens a one-item round straight in the focused view", "renders a view link as the plain gallery", "resolves a backfilled round's artwork from the live payload", "falls back to the plain gallery when a backfilled item is gone".
5. **Stages changing or refused under an open approval form.** A stage unmarked on the canvas while approval mode is open must drop out of `kv_phases`; deselecting every stage must block Send; the api's `nothing_ready` / `too_many_items` races must say what happened instead of "Couldn't request approval". → Task 2 "drops a stage whose marks clear while the approval form is open", "blocks Send for approval once every stage is deselected", "explains a nothing_ready refusal…", "names the per-round cap…".

Known limitation carried over from P0a (not fixed here, check manually): on a focused **motion** item the pin layer covers the video's native controls while the link can pin.

---

## File Structure

All paths relative to the web root (worktree root).

| File | Status | Responsibility |
|---|---|---|
| `docs/prd/client-lane-p0a/web.md` | modify | "Contract (frozen)" gains the multi-item additive notes, byte-identical with the api copy |
| `docs/tracks/client-lane-multi-item.track.md` | create | Track file (frontmatter, status, task checklist, session log, baselines) |
| `src/lib/client-lane/types.ts` | modify | `ApprovalItemPhase`, `ApprovalItem`, `items` on C-1, optional `item_id` on decisions + `DecisionInput` |
| `src/lib/client-lane/round.ts` | create | Pure round helpers: `approvalItemsOf`, `roundItemCount`, `roundVersionIds`, `withItemCount`, `approveLabel`, `ogDecisionPill`, `ogThumbnailUrl`, `shareTitle`, `shareImageAlt` |
| `src/lib/client-lane/round.test.ts` | create | Tests for `round.ts` |
| `src/lib/client-lane/testFixtures.ts` | create | Shared fixtures (items, 3-item KV round, pin comments) — not a test file |
| `src/services/client-lane.ts` | modify | `AgencyApprovalItem`, `items` on rounds, `kv_phases` (drop `kv_ready_item_id`), `ApprovalApiError.max`, `useApprovalVersionLabels` |
| `src/services/client-lane.test.ts` | create | `approvalApiError` reads `max` |
| `src/components/client-lane/agency/RequestApprovalPanel.tsx` | modify | Drop the single-item picker; hook takes `kvPhases`, posts `kv_phases`, toasts `nothing_ready` / `too_many_items`, richer analytics |
| `src/components/studio/kv-generator/KvSharePanel.tsx` | modify | `StageScopeField` shared by both modes; approval mode keeps stages; `readyChoices`/`choices` removed |
| `src/components/studio/kv-generator/KvSharePanel.test.tsx` | modify | 3 approval tests rewritten, 6 added |
| `src/lib/analytics/client-lane-events.ts` | modify | `item_count`/`phases` on `approval_requested`, `item_count` on `decision_submitted`, `phase` on `pin_placed`, new `trackClientGalleryItemOpened` |
| `src/lib/client-lane/pins.ts` | modify | Filter by a version SET, carry `version`, number round-wide |
| `src/lib/client-lane/pins.test.ts` | create | Tests for `pinsFromComments` |
| `src/lib/client-lane/kvTarget.ts` | delete | Replaced by `kv/roundItems.ts` |
| `src/components/client-lane/kv/kvItems.ts` | modify | `kvItemPart` for resize → `tile.{row id}` |
| `src/components/client-lane/kv/roundItems.ts` | create | Items model: `KvRoundItem`, `kvRoundItems`, `itemForPin`, `pinGroups` |
| `src/components/client-lane/kv/roundItems.test.ts` | create | Tests for the model + `kvItemPart` |
| `src/components/client-lane/ui.ts` | modify | `PIN_FILL` constant (the existing pin amber) |
| `src/components/client-lane/PinLayer.tsx` | modify | `draftNumber` prop; `data-client-lane-pin-layer` hook for tests |
| `src/components/client-lane/PinLayer.test.tsx` | create | Draft numbering |
| `src/components/client-lane/kv/swipe.ts` | create | `swipeStep`, `isTypingTarget` |
| `src/components/client-lane/kv/swipe.test.ts` | create | Tests for `swipe.ts` |
| `src/components/client-lane/kv/KvPhaseGrid.tsx` | create | Stage tabs + card grid (the view-link look), optional pin badge |
| `src/components/client-lane/kv/KvLinkGallery.tsx` | create | View-link hero: grid + lightbox (lifted from `KvHero`) |
| `src/components/client-lane/kv/KvLinkGallery.test.tsx` | create | View-link gallery tests |
| `src/components/client-lane/kv/KvFocusedItem.tsx` | create | One item large + PinLayer, ←/→, swipe, back, caption |
| `src/components/client-lane/kv/KvRoundHero.tsx` | create | Round hero: grid ↔ focused view, badges, analytics |
| `src/components/client-lane/kv/KvRoundHero.test.tsx` | create | Round hero tests |
| `src/components/client-lane/hero/KvHero.tsx` | rewrite | Dispatcher: `KvLinkGallery` for `[]`, `KvRoundHero` otherwise |
| `src/components/client-lane/PinList.tsx` | modify | Optional per-item `groups` |
| `src/components/client-lane/DecisionBar.tsx` | modify | `approveLabel` prop replaces `versionLabel` |
| `src/components/client-lane/DecisionPage.tsx` | modify | Items model, pins by version set, controlled focus, copy helpers, analytics |
| `src/components/client-lane/DecisionPage.test.tsx` | create | Page-level tests for a 3-item KV round and every C-1 shape |
| `src/app/s/[token]/page.tsx` | modify | Title/alt via `shareTitle`/`shareImageAlt` |
| `src/app/s/[token]/opengraph-image.tsx` | modify | First item's still + "{n} items · Needs your decision" |
| `src/components/client-lane/agency/ApprovalStatusBlock.tsx` | modify | "Approval · round r · n items"; pin counts on decision rows |
| `src/components/client-lane/agency/ApprovalStatusBlock.test.tsx` | create | Status block tests |
| `src/lib/client-lane/versionLabels.ts` | create | `approvalVersionLabels` (version id → `v{round}`) |
| `src/lib/client-lane/versionLabels.test.ts` | create | Tests |
| `src/lib/studio/kv/kvCommentAdapter.ts` | modify | `versionLabelById` in `kvAnchorLabel` ctx → "on v{round}" |
| `src/lib/studio/kv/kvCommentAdapter.test.ts` | modify | Two tests added |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` | modify | Feed `versionLabelById` into the comment panel's `kvAnchorLabel` |

---

### Task 0: Branch, baselines, contract copy, track file

**Files:**
- Modify: `docs/prd/client-lane-p0a/web.md` (append after line 151, the last bullet of "Additive notes (post-freeze …)")
- Create: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:** none (docs + setup).

- [ ] **Step 1: Create the worktree on the feature branch**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && git merge-base --is-ancestor 6ed9386e8 develop && git merge-base --is-ancestor 7d3091fad develop && git worktree add .worktrees/client-lane-multi-item -b feature/daffa/vc-client-lane-multi-item develop && git -C .worktrees/client-lane-multi-item log --oneline -1
```

Expected: last line starts with the current `develop` tip (`6ed9386e8` or newer). If either `merge-base` fails, stop and tell Daffa — local `develop` lacks the unified New-link form.

- [ ] **Step 2: Install deps and copy the env**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun install && cp ../../.env.local .env.local && ls -la .env.local
```

- [ ] **Step 3: Record baselines**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx tsc --noEmit -p . 2>&1 | grep -c "error TS"; bunx tsc --noEmit -p . 2>&1 | grep -c "KvGeneratorLayout.tsx"
```

Write both numbers into the track file (Step 5). Then run the suites this plan touches, one per invocation, and note pass counts:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvShareBoardCanvas.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/studio/kv/kvCommentAdapter.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/brands/campaign-planner/SharePlanDialog.test.tsx
```

Expected: all pass at HEAD. Any failure here is pre-existing — record it; do not fix.

- [ ] **Step 4: Append the contract additive notes**

Check first whether the api branch already carries its copy:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git show feature/daffa/vc-client-lane-multi-item:docs/prd/client-lane-p0a/api.md 2>/dev/null | sed -n '/^### Additive notes (multi-item approval rounds/,/^## /p'
```

If that prints a section, paste it **verbatim** into `web.md` in place of the block below (the two copies must be byte-identical; if the api text lacks something below, raise it with Daffa instead of silently dropping it). Otherwise insert this block after line 151 of `docs/prd/client-lane-p0a/web.md` (after the `actor_kind` bullet, before the blank line and `## Scope`):

```markdown

### Additive notes (multi-item approval rounds — 2026-09-30)

Spec: `docs/superpowers/specs/2026-09-30-client-lane-multi-item-approval-design.md`. Additive only — every shape above keeps working. A round now freezes N items (`approval_items`); Phase 1 web still makes ONE decision per round.

- **C-9 request** — `POST v1/approvals` for `kv_file` takes `kv_phases: ("sketch" | "craft" | "resize" | "motion")[]` (min 1). `kv_ready_item_id` stays accepted (a one-item set); exactly one of the two is required for `kv_file`, both are prohibited otherwise. New `422 { "code": "nothing_ready" }` when the selected phases hold no ready item and `422 { "code": "too_many_items", "max": 50 }` above the per-round cap. Web sends `kv_phases` only.
- **C-1 `items`** — new top-level `items: [{ "id", "phase": "sketch | craft | resize | motion | deck | plan", "label", "version_id", "status": "pending | approved | approved_with_changes | changes_required | not_relevant", "snapshot": <the KV public item (board | resize | motion) as rendered at request time> | null }]` in round order; `[]` for a `view` link. `snapshot` is `null` for deck / plan and for backfilled rounds. `version` keeps its shape (label `v{round}`, id = the first item's `version_id`). For a KV round with snapshots, `document` is built from them in the same `PublicKvResponse` shape, so `document` item ids equal `items[].version_id`.
- **C-4 pins** — the anchor stays `{phase}:{item.version_id}:{part}`; the Resize part is `tile.{resize row id}` (the public page wrote `tile.{platform_id}` in P0a). `GET …/comments` returns root pins on **every** item of the current round; `POST` answers `422 { "code": "invalid_anchor", "message": "That element is not in this round." }` when the anchor's version is not one of them. Decision `pins` follow the same membership rule.
- **C-3 decision** — optional `item_id` (an `items[].id` of the current round). Phase 1 web never sends it.
- **Decisions** (C-1, C-3 `201`, C-9) — every decision gains `item_id: string | null` (`null` = a decision on the whole round).
- **C-9 list** — each round in `GET v1/approvals` gains `items: [{ "id", "phase", "label", "status", "thumbnail_url": string | null }]`.
- **Labels** — the version label stays `v{round}`; with more than one item, UI and notifications read `v{round} · {n} items`.
```

D-1 is already resolved (see header): copy the C-9 list bullet from the api PRD copy verbatim — it includes `"version_id"`.

- [ ] **Step 5: Create the track file**

Create `docs/tracks/client-lane-multi-item.track.md`:

```markdown
---
prd: client-lane-multi-item-approval
parent_prd: docs/superpowers/specs/2026-09-30-client-lane-multi-item-approval-design.md
service: web
branch: feature/daffa/vc-client-lane-multi-item
worktree: web/.worktrees/client-lane-multi-item
base: develop @ <sha printed in Task 0 Step 1>
flag: show-client-lane (agency side only; /s/* unflagged)
pr_url: null
status: in_progress
---

# Track — Client Lane multi-item approval rounds (web)

Plan: `docs/superpowers/plans/2026-09-30-client-lane-multi-item-web.md`. Contract: "Additive notes (multi-item approval rounds — 2026-09-30)" in `docs/prd/client-lane-p0a/web.md`, byte-identical with the api copy.

## Status

| Item | Status |
|------|--------|
| Spec | approved in chat 2026-09-30 |
| Service PRD (contract notes) | draft — awaiting Jeff |
| Implementation | in_progress |
| PR | not_submitted |

## Baselines (Task 0)

- `tsc` errors, whole project: <number from Step 3>
- `tsc` errors in `KvGeneratorLayout.tsx`: <number from Step 3>
- Pre-existing test failures: <none | list>

## Task Checklist

- [x] Task 0: worktree, baselines, contract notes, this file
- [ ] Task 1: types, services, round helpers
- [ ] Task 2: agency form — stages in approval mode, `kv_phases`
- [ ] Task 3: items model + pins by version set
- [ ] Task 4: grid building blocks (PinLayer, swipe, KvPhaseGrid, KvLinkGallery)
- [ ] Task 5: focused view + KvRoundHero
- [ ] Task 6: DecisionPage integration
- [ ] Task 7: OG card + page title
- [ ] Task 8: status block + editor pin labels
- [ ] Task 9: gates, manual smoke, tri-mode check

## Open

- D-1: `version_id` on C-9 list items (asked <date>).

## Session Log

### 2026-09-30 — daffa (plan executor)
- Task 0 done.
```

Fill the `<…>` values with what Steps 1 and 3 printed (they are measurements, not decisions).

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add docs/prd/client-lane-p0a/web.md docs/tracks/client-lane-multi-item.track.md && git commit -m "$(cat <<'EOF'
docs(web): contract notes + track for multi-item approval rounds

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1: Types, services, round helpers

**Files:**
- Modify: `src/lib/client-lane/types.ts` (line 7 import; after line 38; lines 46-55; lines 100-108; lines 155-162)
- Modify: `src/services/client-lane.ts` (line 9 import; lines 12-21; lines 29-35; lines 88-113)
- Create: `src/lib/client-lane/round.ts`, `src/lib/client-lane/round.test.ts`, `src/lib/client-lane/testFixtures.ts`, `src/services/client-lane.test.ts`

**Interfaces:**
- Consumes: `PublicKvItem` (`src/services/query.ts:6813`).
- Produces:
  - `type ApprovalItemPhase = "sketch" | "craft" | "resize" | "motion" | "deck" | "plan"`
  - `interface ApprovalItem { id: string; phase: ApprovalItemPhase; label: string; version_id: string; status: ApprovalStatus; snapshot: PublicKvItem | null }`
  - `ShareLinkBase.items: ApprovalItem[]`; `ApprovalDecision.item_id?: string | null`; `DecisionInput.item_id?: string`
  - `interface AgencyApprovalItem { id: string; phase: ApprovalItemPhase; label: string; status: ApprovalStatus; thumbnail_url: string | null; version_id?: string }`; `AgencyApproval.items?: AgencyApprovalItem[]`
  - `CreateApprovalInput.kv_phases?: KvSharePhase[]`; `ApprovalApiError.max: number | null`
  - `approvalItemsOf(data: Pick<ShareLinkData, "items">): ApprovalItem[]`
  - `roundItemCount(data: Pick<ShareLinkData, "items">): number`
  - `roundVersionIds(data: Pick<ShareLinkData, "items" | "version">): ReadonlySet<string> | null`
  - `withItemCount(versionLabel: string, count: number): string`
  - `approveLabel(versionLabel: string, count: number): string`
  - `ogDecisionPill(count: number): string`
  - `ogThumbnailUrl(data: ShareLinkData): string | null`
  - fixtures: `HERO`, `STORY`, `FEED`, `CLIP`, `approvalItem()`, `pendingApproval()`, `kvRound()`, `pinComment()`

- [ ] **Step 1: Extend the wire types**

In `src/lib/client-lane/types.ts`, line 7 becomes:

```ts
import type { PublicKvItem, PublicKvResponse } from "@/services/query";
```

Insert after line 38 (end of `ShareVersion`):

```ts

/** What one frozen round item is (multi-item rounds, spec §4.1). */
export type ApprovalItemPhase =
  | "sketch"
  | "craft"
  | "resize"
  | "motion"
  | "deck"
  | "plan";

/**
 * One item frozen into the current round (C-1 `items`). `version_id` is the
 * id the page RENDERS — board tip, newest motion export, resize row — and the
 * id pins anchor on. `snapshot` is the KV public item as it rendered when the
 * round was requested; `null` for deck / plan and for rounds backfilled from
 * before multi-item rounds existed.
 */
export interface ApprovalItem {
  id: string;
  phase: ApprovalItemPhase;
  label: string;
  version_id: string;
  status: ApprovalStatus;
  snapshot: PublicKvItem | null;
}
```

In `ApprovalDecision` (lines 46-55) add after `deferred_until: string | null;`:

```ts
  /**
   * The item this decision is on; `null` = the whole round (every Phase 1
   * decision). Optional so pre-multi-item payloads and fixtures still type.
   */
  item_id?: string | null;
```

In `ShareLinkBase` (lines 100-108) add after `version: ShareVersion;`:

```ts
  /**
   * The round's frozen items in round order; `[]` for a `view` link. Read it
   * through `approvalItemsOf()` (lib/client-lane/round.ts), never directly — an
   * api that predates multi-item rounds omits the key entirely.
   */
  items: ApprovalItem[];
```

In `DecisionInput` (lines 155-162) add after `guest_email?: string;`:

```ts
  /** Per-item decisions (spec Phase 2). Phase 1 web never sends it. */
  item_id?: string;
```

- [ ] **Step 2: Extend the agency service types**

In `src/services/client-lane.ts`, line 9 becomes:

```ts
import type {
  Approval,
  ApprovalItemPhase,
  ApprovalStatus,
  ShareSubjectType,
} from "@/lib/client-lane/types";
import type { KvSharePhase } from "@/types/kv/share-link";
```

Insert before `/** C-9 adds three keys on top of the public approval shape. */` (line 12):

```ts
/** One frozen item of a round as `GET v1/approvals` lists it (C-9, multi-item). */
export interface AgencyApprovalItem {
  id: string;
  phase: ApprovalItemPhase;
  label: string;
  status: ApprovalStatus;
  thumbnail_url: string | null;
  /**
   * The rendered id pins anchor on. NOT in the agreed C-9 list shape — asked
   * for as contract deviation D-1 — so it is read defensively everywhere.
   */
  version_id?: string;
}
```

In `AgencyApproval` (lines 13-21) add after `created_at?: string | null;`:

```ts
  /** The round's frozen items (multi-item rounds). Absent on older payloads. */
  items?: AgencyApprovalItem[];
```

In `CreateApprovalInput` (lines 29-35) add after `kv_ready_item_id?: string;` (Task 2 removes that line):

```ts
  /** KV only: the stages whose ready items the round freezes (C-9, multi-item). */
  kv_phases?: KvSharePhase[];
```

Replace `ApprovalApiError` + `approvalApiError` (lines 88-113) with:

```ts
/** The coded 422s the sheet distinguishes (`already_a_member`, `link_cap`,
 *  `nothing_ready`, `too_many_items`). */
export interface ApprovalApiError {
  status: number | null;
  code: string | null;
  email: string | null;
  message: string | null;
  /** `too_many_items` only: the per-round cap the api enforced. */
  max: number | null;
}

export function approvalApiError(error: unknown): ApprovalApiError {
  const axiosError = error as AxiosError<{
    code?: string;
    email?: string;
    message?: string;
    max?: number;
    errors?: Record<string, string[]>;
  }>;
  const response = axiosError?.response;
  const firstValidation = response?.data?.errors
    ? Object.values(response.data.errors)[0]?.[0]
    : undefined;
  return {
    status: response?.status ?? null,
    code: response?.data?.code ?? null,
    email: response?.data?.email ?? null,
    message: response?.data?.message ?? firstValidation ?? null,
    max: typeof response?.data?.max === "number" ? response.data.max : null,
  };
}
```

- [ ] **Step 3: Create the shared fixtures**

Create `src/lib/client-lane/testFixtures.ts`:

```ts
/**
 * Fixtures shared by the client-lane suites (multi-item rounds). Not a test
 * file — bun never collects it — and no app code imports it.
 */
import type {
  PublicKvBoardItem,
  PublicKvItem,
  PublicKvMotionItem,
  PublicKvResizeItem,
} from "@/services/query";

import type {
  Approval,
  ApprovalItem,
  ApprovalItemPhase,
  PublicComment,
  ShareLinkKv,
} from "./types";

export const HERO: PublicKvBoardItem = {
  id: "g1",
  kind: "board",
  name: "Hero board",
  image_url: "https://cdn.test/g1.png",
  aspect_ratio: "1:1",
  is_master: true,
  overlays: [],
};

export const STORY: PublicKvResizeItem = {
  id: "r1",
  kind: "resize",
  platform_id: "instagram-story",
  platform_label: "IG Story",
  width: 1080,
  height: 1920,
  image_url: "https://cdn.test/r1.png",
  overlays: [],
  source_overlays: null,
  source_width: null,
  source_height: null,
};

export const FEED: PublicKvResizeItem = {
  ...STORY,
  id: "r2",
  platform_id: "instagram-post",
  platform_label: "IG Feed",
  height: 1080,
  image_url: "https://cdn.test/r2.png",
};

export const CLIP: PublicKvMotionItem = {
  id: "m1",
  kind: "motion",
  video_url: "https://cdn.test/m1.mp4",
  ratio: "9:16",
  width: 1080,
  height: 1920,
  duration_ms: 8000,
};

/** A frozen item whose snapshot IS the rendered item (version_id = its id). */
export function approvalItem(
  snapshot: PublicKvItem,
  phase: ApprovalItemPhase,
  overrides: Partial<ApprovalItem> = {}
): ApprovalItem {
  return {
    id: `ai_${snapshot.id}`,
    phase,
    label: `${phase} · ${snapshot.id}`,
    version_id: snapshot.id,
    status: "pending",
    snapshot,
    ...overrides,
  };
}

export function pendingApproval(overrides: Partial<Approval> = {}): Approval {
  return {
    id: "ap1",
    round: 1,
    policy: "optional",
    status: "pending",
    message: null,
    sent_at: "2026-09-30T00:00:00.000Z",
    deferred_until: null,
    deferred_note: null,
    resolved_at: null,
    approvers: [],
    decisions: [],
    rounds: [],
    ...overrides,
  };
}

/** A three-item KV round: one Craft board, two Resize tiles, open for a decision. */
export function kvRound(overrides: Partial<ShareLinkKv> = {}): ShareLinkKv {
  return {
    type: "kv_file",
    brand: { name: "Garuda", slug: "garuda", logo_url: null },
    workspace: { name: "Alva" },
    subject: {
      id: "f1",
      title: "Ramadan hero",
      thumbnail_url: "https://cdn.test/thumb.png",
    },
    version: { type: "kv_generation", id: "g1", label: "v1", created_at: null },
    items: [
      approvalItem(HERO, "craft"),
      approvalItem(STORY, "resize"),
      approvalItem(FEED, "resize"),
    ],
    document: {
      name: "Ramadan hero",
      brand_slug: "garuda",
      phases: [
        { phase: "craft", items: [HERO] },
        { phase: "resize", items: [STORY, FEED] },
      ],
    },
    approval: pendingApproval(),
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

/** A root pin comment as C-4 returns it. */
export function pinComment(
  id: string,
  anchorId: string,
  createdAt: string,
  overrides: Partial<PublicComment> = {}
): PublicComment {
  return {
    id,
    commentable_type: "studio_file",
    commentable_id: "f1",
    anchor: { kind: "pin", id: anchorId, x: 0.5, y: 0.5 },
    parent_id: null,
    author: { id: null, name: "Dina", guest: true },
    body: `Note ${id}`,
    created_at: createdAt,
    updated_at: createdAt,
    ...overrides,
  };
}
```

- [ ] **Step 4: Write the failing tests**

Create `src/lib/client-lane/round.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  approvalItemsOf,
  approveLabel,
  ogDecisionPill,
  ogThumbnailUrl,
  roundItemCount,
  roundVersionIds,
  withItemCount,
} from "./round";
import { CLIP, HERO, approvalItem, kvRound } from "./testFixtures";
import type { ShareLinkData } from "./types";

describe("approvalItemsOf / roundItemCount", () => {
  it("reads the round's items", () => {
    expect(approvalItemsOf(kvRound()).map((i) => i.id)).toEqual([
      "ai_g1",
      "ai_r1",
      "ai_r2",
    ]);
    expect(roundItemCount(kvRound())).toBe(3);
  });

  it("treats a response without `items` (api mid-deploy) as no items", () => {
    const legacy = { ...kvRound(), items: undefined } as unknown as ShareLinkData;
    expect(approvalItemsOf(legacy)).toEqual([]);
    expect(roundItemCount(legacy)).toBe(0);
  });
});

describe("roundVersionIds", () => {
  it("is the set of every item's version id", () => {
    expect([...(roundVersionIds(kvRound()) ?? [])]).toEqual(["g1", "r1", "r2"]);
  });

  it("falls back to version.id when there are no items", () => {
    expect([...(roundVersionIds(kvRound({ items: [] })) ?? [])]).toEqual(["g1"]);
  });

  it("is null when nothing scopes the pins (a live view link)", () => {
    const view = kvRound({
      items: [],
      version: { type: "live", id: null, label: "Latest", created_at: null },
    });
    expect(roundVersionIds(view)).toBeNull();
  });
});

describe("copy helpers", () => {
  it("adds the item count only when a round has more than one item", () => {
    expect(withItemCount("v2", 3)).toBe("v2 · 3 items");
    expect(withItemCount("v2", 1)).toBe("v2");
    expect(withItemCount("v2", 0)).toBe("v2");
  });

  it("approves the whole set by count, a single item by version", () => {
    expect(approveLabel("v2", 3)).toBe("Approve all 3");
    expect(approveLabel("v2", 1)).toBe("Approve v2");
  });

  it("puts the item count on the OG decision pill for a set", () => {
    expect(ogDecisionPill(4)).toBe("4 items · Needs your decision");
    expect(ogDecisionPill(1)).toBe("Needs your decision");
  });
});

describe("ogThumbnailUrl", () => {
  it("uses the first item's frozen still", () => {
    expect(ogThumbnailUrl(kvRound())).toBe(HERO.image_url);
  });

  it("falls back to the subject thumbnail when the first item has no still", () => {
    const motionFirst = kvRound({ items: [approvalItem(CLIP, "motion")] });
    expect(ogThumbnailUrl(motionFirst)).toBe("https://cdn.test/thumb.png");
  });

  it("falls back to the subject thumbnail for a backfilled or deck item", () => {
    const backfilled = kvRound({
      items: [approvalItem(HERO, "craft", { snapshot: null })],
    });
    expect(ogThumbnailUrl(backfilled)).toBe("https://cdn.test/thumb.png");
  });
});
```

Create `src/services/client-lane.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { approvalApiError } from "./client-lane";

describe("approvalApiError", () => {
  it("carries the api's per-round cap on too_many_items", () => {
    const err = approvalApiError({
      response: {
        status: 422,
        data: { code: "too_many_items", max: 50, message: "Too many." },
      },
    });
    expect(err).toMatchObject({ status: 422, code: "too_many_items", max: 50 });
  });

  it("reads max as null when the api sent none", () => {
    const err = approvalApiError({
      response: { status: 422, data: { code: "nothing_ready" } },
    });
    expect(err.code).toBe("nothing_ready");
    expect(err.max).toBeNull();
  });
});
```

- [ ] **Step 5: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/round.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/services/client-lane.test.ts
```

Expected: `round.test.ts` fails to resolve `./round`. `client-lane.test.ts` PASSES already (Step 2 implemented it) — that is fine; its mutation check is Step 8.

- [ ] **Step 6: Implement `round.ts`**

Create `src/lib/client-lane/round.ts`:

```ts
/**
 * Pure helpers over a multi-item approval round (C-1 `items`, spec §6.2).
 * One place for "how many items", "which versions scope the pins" and every
 * "v2 · 3 items" string, so the page, the metadata and the OG card agree.
 */
import type { PublicKvItem } from "@/services/query";

import type { ApprovalItem, ShareLinkData } from "./types";

/**
 * The round's frozen items. `[]` for a `view` link — and for a response from
 * an api that predates multi-item rounds, so a page served mid-deploy still
 * renders (spec §10: the public page handles both shapes).
 */
export function approvalItemsOf(
  data: Pick<ShareLinkData, "items">
): ApprovalItem[] {
  return Array.isArray(data.items) ? data.items : [];
}

export function roundItemCount(data: Pick<ShareLinkData, "items">): number {
  return approvalItemsOf(data).length;
}

/**
 * The versions whose pins belong on this page: every item of the round. With
 * no items (a pre-multi-item api) it is the single frozen version; `null`
 * means nothing scopes them (a live view link, where pins are off anyway).
 */
export function roundVersionIds(
  data: Pick<ShareLinkData, "items" | "version">
): ReadonlySet<string> | null {
  const ids = approvalItemsOf(data).map((item) => item.version_id);
  if (ids.length > 0) return new Set(ids);
  return data.version.id ? new Set([data.version.id]) : null;
}

/** "v2 · 3 items" for a set; the bare label for one item (or none). */
export function withItemCount(versionLabel: string, count: number): string {
  return count > 1 ? `${versionLabel} · ${count} items` : versionLabel;
}

/** The decision bar's approve button. */
export function approveLabel(versionLabel: string, count: number): string {
  return count > 1 ? `Approve all ${count}` : `Approve ${versionLabel}`;
}

/** The OG card's pill while the round is open. */
export function ogDecisionPill(count: number): string {
  return count > 1
    ? `${count} items · Needs your decision`
    : "Needs your decision";
}

function stillOf(item: PublicKvItem | null): string | null {
  if (!item || item.kind === "motion") return null;
  return item.image_url;
}

/**
 * The OG card's picture: the first item's frozen still, else the subject
 * thumbnail (a motion clip, a layer-composed tile, a deck or plan item, or a
 * backfilled round has no still of its own).
 */
export function ogThumbnailUrl(data: ShareLinkData): string | null {
  const first = approvalItemsOf(data)[0];
  return stillOf(first?.snapshot ?? null) ?? data.subject.thumbnail_url;
}
```

- [ ] **Step 7: Run — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/round.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/services/client-lane.test.ts
```

- [ ] **Step 8: Mutation check**

One at a time, confirm FAIL then restore: (a) `approvalItemsOf` returns `data.items` unguarded → the "mid-deploy" test fails; (b) `withItemCount` uses `count > 0` → "bare label for one item" fails; (c) `roundVersionIds` returns `null` when items are empty → fallback test fails; (d) `ogThumbnailUrl` returns `first?.snapshot?.image_url` without the motion guard → type error or motion test fails; (e) `approvalApiError` drops the `max` line → first services test fails.

- [ ] **Step 9: Format, lint, type-check, commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx prettier --write src/lib/client-lane/types.ts src/lib/client-lane/round.ts src/lib/client-lane/round.test.ts src/lib/client-lane/testFixtures.ts src/services/client-lane.ts src/services/client-lane.test.ts && bunx eslint src/lib/client-lane/types.ts src/lib/client-lane/round.ts src/lib/client-lane/round.test.ts src/lib/client-lane/testFixtures.ts src/services/client-lane.ts src/services/client-lane.test.ts && bunx tsc --noEmit -p . 2>&1 | grep -E "src/(lib/client-lane/(types|round|testFixtures)|services/client-lane)"
```

Expected: the final grep prints nothing. (The `items` field is now required on `ShareLinkData`; if any non-test code builds a `ShareLinkData` literal, tsc names it here — add `items: []` there.)

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add src/lib/client-lane/types.ts src/lib/client-lane/round.ts src/lib/client-lane/round.test.ts src/lib/client-lane/testFixtures.ts src/services/client-lane.ts src/services/client-lane.test.ts && git commit -m "$(cat <<'EOF'
feat(web): client lane wire types + round helpers for multi-item rounds

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Agency form — stages in approval mode, posts `kv_phases`

**Files:**
- Modify: `src/components/client-lane/agency/RequestApprovalPanel.tsx` (lines 27, 47-56, 68-189, 191-375, 401-443)
- Modify: `src/components/studio/kv-generator/KvSharePanel.tsx` (lines 34-39, 139-156, 219-236, 591-615, 753-830, 917-971)
- Modify: `src/services/client-lane.ts` (remove `kv_ready_item_id` from `CreateApprovalInput`)
- Modify: `src/lib/analytics/client-lane-events.ts` (lines 3-7, 67-77)
- Test: `src/components/studio/kv-generator/KvSharePanel.test.tsx` (top imports; lines 701-762, 782-807; new tests before line 809)

**Interfaces:**
- Consumes: `CreateApprovalInput.kv_phases`, `approvalApiError(...).max` (Task 1).
- Produces:
  - `useApprovalRequestForm(args: { subjectType: ShareSubjectType; subjectId: string; brandId?: string | null; kvPhases?: KvSharePhase[]; entry: ApprovalRequestEntry; onCreated: (result: CreateApprovalResponse) => void }): ApprovalRequestForm` — `kvMissing` true for `kv_file` with no phases; no `readyItemId`/`setReadyItemId`.
  - `ApprovalFields({ form }: { form: ApprovalRequestForm })`
  - `RequestApprovalPanel` props without `kvChoices`; `KvReadyChoice` deleted.
  - `trackApprovalRequested` props gain `item_count: number; phases: KvSharePhase[]`.

- [ ] **Step 1: Rewrite the approval tests (failing)**

In `KvSharePanel.test.tsx`, add after line 9 (`import axiosInstance from "@/services/axios";`):

```tsx
import posthog from "posthog-js";
```

Replace the test at lines 701-731 ("swaps the link settings for the approval fields when switched on") with:

```tsx
  it("keeps the stage picker and swaps only the link settings when switched on", async () => {
    stubApprovalsApi();
    const user = userEvent.setup();

    renderPanel();
    await openCreateForm(user);
    await user.click(body().getByRole("switch", { name: "Request approval" }));

    // Same scope control as a view link — counts, defaults, disabled rule
    // (spec §6.1).
    expect(body().getByText("Select stages to include")).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: /^Craft\s*1$/ })
    ).toBeInTheDocument();
    expect(body().getByRole("button", { name: /^Sketch\s*0$/ })).toBeDisabled();
    // The single-item picker is gone.
    expect(body().queryByText("Which item needs a decision?")).toBeNull();
    // Expiry, label and passcode have nothing to act on for an approval link.
    expect(body().queryByText("Expiration duration")).toBeNull();
    expect(body().queryByLabelText("Link label")).toBeNull();
    expect(body().queryByText("Require passcode access")).toBeNull();
    expect(body().getByLabelText("Approver email")).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Send for approval" })
    ).toBeInTheDocument();
    expect(body().queryByRole("button", { name: "Create link" })).toBeNull();
  });
```

Replace the test at lines 733-762 ("sends the chosen item, approvers and message, then shows the send step") with:

```tsx
  it("sends the chosen stages, approvers and message, then shows the send step", async () => {
    const post = stubApprovalsApi();
    const user = userEvent.setup();

    renderPanel();
    await openCreateForm(user);
    await user.click(body().getByRole("switch", { name: "Request approval" }));
    // Craft is preselected; add Resize alongside it.
    await user.click(body().getByRole("button", { name: /^Resize/ }));
    await user.type(
      body().getByLabelText("Approver email"),
      "dina@brand.co.id{Enter}"
    );
    expect(body().getByText("dina@brand.co.id")).toBeInTheDocument();
    await user.type(body().getByLabelText("What changed"), "Smaller logo");
    await user.click(body().getByRole("button", { name: "Send for approval" }));

    await waitFor(() => expect(post).toHaveBeenCalled());
    expect(post).toHaveBeenCalledWith("v1/approvals", {
      subject_type: "kv_file",
      subject_id: "f1",
      approver_emails: ["dina@brand.co.id"],
      message: "Smaller logo",
      kv_phases: ["craft", "resize"],
    });
    expect(post.mock.calls[0][1]).not.toHaveProperty("kv_ready_item_id");
    expect(await body().findByText(/out for approval/)).toBeInTheDocument();
    // Link creation is a different endpoint — the view-link mutation stays idle.
    expect(createMutate).not.toHaveBeenCalled();
  });
```

In "reopens the form in approval mode from Request round N", replace lines 804-806 (the `getByText("Which item needs a decision?")` expectation) with:

```tsx
    expect(body().getByText("Select stages to include")).toBeInTheDocument();
    expect(body().queryByText("Which item needs a decision?")).toBeNull();
```

Insert before `it("renders no toggle at all while the client lane is off"` (line 809):

```tsx
  it("blocks Send for approval once every stage is deselected", async () => {
    stubApprovalsApi();
    const user = userEvent.setup();

    renderPanel();
    await openCreateForm(user);
    await user.click(body().getByRole("switch", { name: "Request approval" }));
    await user.click(body().getByRole("button", { name: /^Craft/ }));

    expect(
      body().getByRole("button", { name: "Send for approval" })
    ).toBeDisabled();
  });

  it("drops a stage whose marks clear while the approval form is open", async () => {
    const post = stubApprovalsApi();
    const user = userEvent.setup();

    const { rerender } = renderPanel();
    await openCreateForm(user);
    await user.click(body().getByRole("switch", { name: "Request approval" }));
    await user.click(body().getByRole("button", { name: /^Resize/ }));
    // Someone unmarks the Craft board on the canvas while this form is open.
    rerender(
      <KvSharePanel
        fileId="f1"
        items={items}
        readyToShareMap={{ ...readyToShareMap, craft: [] }}
        open
      />
    );
    await user.click(body().getByRole("button", { name: "Send for approval" }));

    await waitFor(() => expect(post).toHaveBeenCalled());
    expect(post.mock.calls[0][1]).toMatchObject({ kv_phases: ["resize"] });
  });

  it("explains a nothing_ready refusal instead of a generic failure", async () => {
    const post = stubApprovalsApi();
    post.mockRejectedValueOnce({
      response: {
        status: 422,
        data: { code: "nothing_ready", message: "Nothing ready." },
      },
    });
    const user = userEvent.setup();

    renderPanel();
    await openCreateForm(user);
    await user.click(body().getByRole("switch", { name: "Request approval" }));
    await user.click(body().getByRole("button", { name: "Send for approval" }));

    await waitFor(() =>
      expect(showToast).toHaveBeenCalledWith(
        "Nothing ready to send",
        expect.stringContaining("marked ready to share"),
        "error"
      )
    );
  });

  it("names the per-round cap when the api refuses too many items", async () => {
    const post = stubApprovalsApi();
    post.mockRejectedValueOnce({
      response: {
        status: 422,
        data: { code: "too_many_items", max: 50, message: "Too many." },
      },
    });
    const user = userEvent.setup();

    renderPanel();
    await openCreateForm(user);
    await user.click(body().getByRole("switch", { name: "Request approval" }));
    await user.click(body().getByRole("button", { name: "Send for approval" }));

    await waitFor(() =>
      expect(showToast).toHaveBeenCalledWith(
        "Too many items for one round",
        expect.stringContaining("up to 50 items"),
        "error"
      )
    );
  });

  it("reports the frozen item count and stages on approval_requested", async () => {
    const post = stubApprovalsApi();
    post.mockResolvedValueOnce({
      data: {
        data: {
          approval: approvalRound({
            status: "pending",
            resolved_at: null,
            items: [1, 2, 3, 4].map((n) => ({
              id: `ai${n}`,
              phase: "resize",
              label: `Resize ${n}`,
              status: "pending",
              thumbnail_url: null,
            })),
          }),
          share_url: "https://frndos.test/s/cmt_tok",
          approvers: [],
        },
      },
    });
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const user = userEvent.setup();

    renderPanel();
    await openCreateForm(user);
    await user.click(body().getByRole("switch", { name: "Request approval" }));
    await user.click(body().getByRole("button", { name: /^Resize/ }));
    await user.click(body().getByRole("button", { name: "Send for approval" }));

    await waitFor(() =>
      expect(capture).toHaveBeenCalledWith(
        "client_lane.approval_requested",
        expect.objectContaining({
          item_count: 4,
          phases: ["craft", "resize"],
          entry: "link_toggle",
        })
      )
    );
  });
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: the rewritten/added approval tests fail (stages hidden in approval mode, `kv_ready_item_id` posted, generic toasts, no `item_count`); every other test passes.

- [ ] **Step 3: Analytics props**

In `src/lib/analytics/client-lane-events.ts`, lines 3-7 become:

```ts
import type {
  ApprovalPolicy,
  DecisionOutcome,
  ShareSubjectType,
} from "@/lib/client-lane/types";
import type { KvSharePhase } from "@/types/kv/share-link";
```

In `trackApprovalRequested` (lines 68-77) add after `entry: ApprovalRequestEntry;`:

```ts
  /** Items frozen into the round (C-9 `approval.items`); 1 for deck / plan. */
  item_count: number;
  /** KV stages the round was requested over; `[]` for deck / plan. */
  phases: KvSharePhase[];
```

- [ ] **Step 4: Drop `kv_ready_item_id` from the service input**

In `src/services/client-lane.ts` `CreateApprovalInput`, delete the line `kv_ready_item_id?: string;` (web never sends it again; the api still accepts it for old clients).

- [ ] **Step 5: Rework `RequestApprovalPanel.tsx`**

Line 27 becomes:

```ts
import type { ShareSubjectType } from "@/lib/client-lane/types";
import type { KvSharePhase } from "@/types/kv/share-link";
```

Delete lines 47-56 (`KvReadyChoice` and its doc comment).

In `RequestApprovalPanel` (lines 68-115): delete the `kvChoices,` destructure (line 73), its prop type + doc (lines 84-85) and the `kvChoices={kvChoices}` pass-through (line 109). Update the doc comment's last paragraph (lines 64-66) to:

```ts
 * The deck and plan sheets use this whole panel. The KV sheet folds the same
 * pieces (`useApprovalRequestForm` + `ApprovalFields` + `ApprovalSendStep`)
 * into its New-link form behind a "Request approval" toggle, scoped by the
 * same stage pills as a view link (multi-item rounds, spec §6.1).
```

In `RequestForm` (lines 117-189): delete `kvChoices,` (line 121), `kvChoices?: KvReadyChoice[];` (line 129), `kvChoices,` in the hook call (line 138), and change line 166 to `<ApprovalFields form={form} />`.

Replace the whole `useApprovalRequestForm` (lines 191-375) with:

```tsx
/**
 * Everything a request-approval form holds — approver emails (validated,
 * committed on Enter / comma / space / blur), the message — and the submit
 * that creates the round. Shared by `RequestApprovalPanel` and the KV
 * New-link form so both send exactly the same `POST v1/approvals`.
 *
 * KV rounds are scoped by STAGE (`kvPhases`, owned by the host's stage
 * pills): the api freezes every ready item in those stages (spec §5.1).
 */
export function useApprovalRequestForm({
  subjectType,
  subjectId,
  brandId,
  kvPhases,
  entry,
  onCreated,
}: {
  subjectType: ShareSubjectType;
  subjectId: string;
  brandId?: string | null;
  /** KV only: the selected stages. Live — the host prunes unmarked ones. */
  kvPhases?: KvSharePhase[];
  entry: ApprovalRequestEntry;
  onCreated: (result: CreateApprovalResponse) => void;
}) {
  const showToast = useToastStore((s) => s.showToast);
  const create = useCreateApproval(subjectType, subjectId);

  const [emails, setEmails] = useState<string[]>([]);
  const [emailDraft, setEmailDraft] = useState("");
  const [emailError, setEmailError] = useState<string | null>(null);
  const [message, setMessage] = useState("");

  // Existing clients of the brand (the locked `client` role) as one-tap
  // suggestions. The members endpoint carries no `scope`, so the role name is
  // the discriminator until a dedicated listing exists.
  const members = useBrandMembers(brandId ?? "");
  const suggestions = useMemo(() => {
    const rows = ((
      members.data as { brand_members?: BrandMemberRow[] } | undefined
    )?.brand_members ?? []) as BrandMemberRow[];
    return rows
      .filter(
        (m) =>
          m.email &&
          (m.brand_role?.name ?? "").toLowerCase() === "client" &&
          !emails.includes(m.email.toLowerCase())
      )
      .slice(0, 6);
  }, [members.data, emails]);

  const addEmail = (raw: string): boolean => {
    const value = raw.trim().toLowerCase().replace(/,$/, "");
    if (!value) return false;
    if (!EMAIL.test(value)) {
      setEmailError("That doesn't look like an email address.");
      return false;
    }
    if (emails.includes(value)) {
      setEmailDraft("");
      return true;
    }
    if (emails.length >= MAX_APPROVERS) {
      setEmailError(`Up to ${MAX_APPROVERS} approvers per round.`);
      return false;
    }
    setEmails((prev) => [...prev, value]);
    setEmailDraft("");
    setEmailError(null);
    return true;
  };

  const removeEmail = (email: string) =>
    setEmails((prev) => prev.filter((e) => e !== email));

  const kvMissing =
    subjectType === "kv_file" && (kvPhases?.length ?? 0) === 0;

  const submit = () => {
    if (create.isPending) return;
    // `addEmail` commits through `setEmails`, which doesn't land before this
    // function's own closure over `emails` reads it again — a draft typed
    // and submitted in one motion (no blur, no Enter) was silently dropped.
    // Resolve the final list locally instead of relying on that state update.
    let finalEmails = emails;
    const draft = emailDraft.trim();
    if (draft) {
      const value = draft.toLowerCase().replace(/,$/, "");
      if (!EMAIL.test(value)) {
        setEmailError("That doesn't look like an email address.");
        return;
      }
      if (!finalEmails.includes(value)) {
        if (finalEmails.length >= MAX_APPROVERS) {
          setEmailError(`Up to ${MAX_APPROVERS} approvers per round.`);
          return;
        }
        finalEmails = [...finalEmails, value];
        setEmails(finalEmails);
      }
      setEmailDraft("");
      setEmailError(null);
    }
    if (kvMissing) return;
    // Snapshot the stages once so the payload and the event agree.
    const phases = subjectType === "kv_file" ? [...(kvPhases ?? [])] : [];
    create.mutate(
      {
        approver_emails: finalEmails,
        message: message.trim() || undefined,
        ...(subjectType === "kv_file" ? { kv_phases: phases } : {}),
      },
      {
        onSuccess: (created) => {
          trackApprovalRequested({
            subject_type: subjectType,
            policy: created.approval.policy,
            round: created.approval.round,
            approver_count: finalEmails.length,
            has_message: message.trim().length > 0,
            mail_sent_count: created.approvers.filter((a) => a.mail_sent)
              .length,
            entry,
            // A-1: the 201 approval carries `items` like the list does.
            item_count: created.approval.items?.length ?? 1,
            phases,
          });
          onCreated(created);
        },
        onError: (error) => {
          const err = approvalApiError(error);
          trackApprovalRequestFailed({
            subject_type: subjectType,
            approver_count: finalEmails.length,
            reason: failureReason(err),
            http_status: err.status,
          });
          if (err.code === "already_a_member") {
            setEmailError(
              `${err.email ?? "That address"} is already a member of this workspace — they can approve from inside frndOS.`
            );
            return;
          }
          if (err.code === "link_cap") {
            showToast(
              "Link limit reached",
              "Revoke a share link on this item to request approval.",
              "error"
            );
            return;
          }
          // Marks changed between the pills rendering and the api freezing.
          if (err.code === "nothing_ready") {
            showToast(
              "Nothing ready to send",
              "The stages you picked have nothing marked ready to share any more. Mark an item on the canvas, then send again.",
              "error"
            );
            return;
          }
          if (err.code === "too_many_items") {
            showToast(
              "Too many items for one round",
              `An approval round holds up to ${err.max ?? 50} items — pick fewer stages.`,
              "error"
            );
            return;
          }
          showToast(
            "Couldn't request approval",
            err.message ?? "Try again in a moment.",
            "error"
          );
        },
      }
    );
  };

  return {
    emails,
    emailDraft,
    setEmailDraft,
    emailError,
    setEmailError,
    addEmail,
    removeEmail,
    popEmail: () => setEmails((prev) => prev.slice(0, -1)),
    suggestions,
    message,
    setMessage,
    kvMissing,
    submit,
    pending: create.isPending,
  };
}
```

Replace `ApprovalFields`' doc + signature + the KV section (lines 401-443) with:

```tsx
/**
 * The approval fields — the approvers and "what changed" — without a header,
 * actions or scope, so each host frames them its own way (the KV form puts
 * its stage pills above them).
 */
export function ApprovalFields({ form }: { form: ApprovalRequestForm }) {
  return (
    <div className="flex flex-col gap-5">
```

(the `<section>` for "Approvers · optional" that was at line 445 now follows directly).

- [ ] **Step 6: Rework `KvSharePanel.tsx`**

Lines 34-39 become:

```tsx
import {
  ApprovalFields,
  ApprovalSendStep,
  useApprovalRequestForm,
} from "@/components/client-lane/agency/RequestApprovalPanel";
```

Delete lines 139-156 (the `readyChoices` comment + `useMemo`). In the `approval={…}` object (lines 219-236) delete `choices: readyChoices,` (line 225).

In `ApprovalModeProps` (lines 591-603) delete lines 597-598 (`/** One per marked item … */` and `choices: KvReadyChoice[];`).

Replace the `CreateLinkForm` doc comment's second paragraph (lines 610-615) with:

```tsx
 *  Behind the client-lane flag the same form also requests approval: its
 *  "Request approval" toggle keeps the stage pills (an approval round freezes
 *  every ready item in the chosen stages — spec §6.1) and swaps only expiry,
 *  label and passcode for approvers + what changed, and "Create link" for
 *  "Send for approval". An approval link reuses one never-expiring `comment`
 *  link across rounds, so the link settings have nothing to act on there. */
```

Replace lines 753-830 (from `{approval && showApprovalFields ? (` through the closing `</section>` of the stage block) with:

```tsx
      {approval && showApprovalFields ? (
        <>
          <div className="mt-4">
            <StageScopeField
              available={available}
              shareable={shareable}
              phases={phases}
              readyCount={readyCount}
              onToggle={togglePhase}
            />
          </div>
          <KvApprovalForm
            approval={approval}
            kvPhases={phases}
            // The toggle flipped on inside New link, or the form opened in
            // approval mode from "Request round N".
            entry={approval.initialOn ? "request_another" : "link_toggle"}
            onCancel={onCancel}
            onSent={setSent}
          />
        </>
      ) : (
        <>
          <div className="mt-4 space-y-5">
            <StageScopeField
              available={available}
              shareable={shareable}
              phases={phases}
              readyCount={readyCount}
              onToggle={togglePhase}
            />
```

(the `<section>` "Expiration duration" that was at line 832 follows unchanged).

Replace `KvApprovalForm` (lines 917-971) with the two components below:

```tsx
/** "Select stages to include" — the create form's scope control in BOTH
 *  modes, so a view link and an approval round are scoped by the same pills,
 *  counts and disabled-when-unmarked rule (spec §6.1). */
function StageScopeField({
  available,
  shareable,
  phases,
  readyCount,
  onToggle,
}: {
  available: KvSharePhase[];
  shareable: KvSharePhase[];
  phases: KvSharePhase[];
  readyCount: (phase: KvSharePhase) => number;
  onToggle: (phase: KvSharePhase) => void;
}) {
  return (
    <section>
      <SectionLabel>Select stages to include</SectionLabel>
      {/* PillTabs rather than SegmentedControl: stage scope is MULTI-select
          (a link can carry Sketch + Craft), and each PillTab owns its own
          `active`/`onClick`, whereas SegmentedControl models one activeId.
          The check leads the selected pill so multi-select reads as ticked,
          not merely highlighted. The number inside each pill is that phase's
          live ready-to-share count, so picking a scope and seeing what the
          client gets is one control, not two. */}
      {available.length === 0 ? (
        <p className="font-geist text-textXs text-text-inverse-subtlest">
          Nothing on the canvas to share yet.
        </p>
      ) : shareable.length === 0 ? (
        // Content exists but none of it is marked — say where the marking
        // happens instead of showing a row of dead pills.
        <div className="frndos-modal-card flex flex-col items-center gap-2 rounded-xl border border-white/[0.07] px-4 py-6 text-center">
          <ShareNetwork
            size={24}
            className="text-text-inverse-subtlest"
            aria-hidden
          />
          <p className="font-geist text-textSmMedium text-text-inverse">
            Nothing marked ready to share
          </p>
          <p className="font-geist text-textXs text-text-inverse-subtlest">
            Click{" "}
            <span className="text-text-inverse-subtle">
              Mark ready to share
            </span>{" "}
            next to a board or tile on the canvas, then come back here.
          </p>
        </div>
      ) : (
        <PillTabs
          size="small"
          tabs={available.map((phase) => ({
            label: KV_SHARE_PHASE_LABEL[phase],
            active: phases.includes(phase),
            disabled: readyCount(phase) === 0,
            title:
              readyCount(phase) === 0
                ? `Nothing in ${KV_SHARE_PHASE_LABEL[phase]} is marked ready to share yet`
                : undefined,
            onClick: () => onToggle(phase),
            leading: phases.includes(phase) ? (
              <Check size={14} weight="bold" />
            ) : undefined,
            badge: (
              <span
                className={
                  phases.includes(phase)
                    ? "font-mono text-textXs text-text-default-subtle"
                    : "font-mono text-textXs text-text-inverse-subtlest"
                }
              >
                {readyCount(phase)}
              </span>
            ),
          }))}
        />
      )}
    </section>
  );
}

/** The create form's approval mode below the stage pills: name approvers
 *  (optional), say what changed, send. Its own component so the request hook
 *  only lives while the toggle is on. */
function KvApprovalForm({
  approval,
  kvPhases,
  entry,
  onCancel,
  onSent,
}: {
  approval: ApprovalModeProps;
  /** The stage pills' live selection — pruned when marks clear. */
  kvPhases: KvSharePhase[];
  entry: ApprovalRequestEntry;
  onCancel: () => void;
  onSent: (result: CreateApprovalResponse) => void;
}) {
  const form = useApprovalRequestForm({
    subjectType: "kv_file",
    subjectId: approval.fileId,
    brandId: approval.brandId,
    kvPhases,
    entry,
    onCreated: onSent,
  });

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        form.submit();
      }}
    >
      <div className="mt-5">
        <ApprovalFields form={form} />
      </div>
      <div className="mt-6 flex items-center gap-2">
        <Button
          type="submit"
          variant="primary"
          size="small"
          loading={form.pending}
          disabled={form.pending || form.kvMissing}
        >
          Send for approval
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

- [ ] **Step 7: Run — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/brands/campaign-planner/SharePlanDialog.test.tsx
```

Expected: all pass (the plan dialog proves `RequestApprovalPanel` still works without an item picker).

- [ ] **Step 8: Mutation check**

One at a time: (a) render only `KvApprovalForm` (drop the approval-mode `StageScopeField`) → "keeps the stage picker…" fails; (b) post `kv_ready_item_id: "x"` instead of `kv_phases` → "sends the chosen stages…" fails; (c) pass `kvPhases={["craft", "resize"]}` (a frozen array) to `KvApprovalForm` instead of `phases` → "drops a stage…" fails; (d) make `kvMissing` always `false` → "blocks Send…" fails; (e) delete the `nothing_ready` branch → its test fails (generic toast); (f) hard-code `50` instead of `err.max ?? 50` and send `max: 30` in the test temporarily → fails (restore the test to 50 after); (g) send `item_count: 1` → analytics test fails.

- [ ] **Step 9: Format, lint, type-check, commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx prettier --write src/components/client-lane/agency/RequestApprovalPanel.tsx src/components/studio/kv-generator/KvSharePanel.tsx src/components/studio/kv-generator/KvSharePanel.test.tsx src/lib/analytics/client-lane-events.ts src/services/client-lane.ts && bunx eslint src/components/client-lane/agency/RequestApprovalPanel.tsx src/components/studio/kv-generator/KvSharePanel.tsx src/components/studio/kv-generator/KvSharePanel.test.tsx src/lib/analytics/client-lane-events.ts src/services/client-lane.ts && bunx tsc --noEmit -p . 2>&1 | grep -E "RequestApprovalPanel|KvSharePanel|client-lane-events|services/client-lane"; wc -c src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: grep prints nothing; the test file is < 45 000 bytes.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add src/components/client-lane/agency/RequestApprovalPanel.tsx src/components/studio/kv-generator/KvSharePanel.tsx src/components/studio/kv-generator/KvSharePanel.test.tsx src/lib/analytics/client-lane-events.ts src/services/client-lane.ts && git commit -m "$(cat <<'EOF'
feat(web): request KV approval over stages, not one item

Approval mode keeps the "Select stages to include" pills and posts
kv_phases; the single-item picker and readyChoices are gone.
nothing_ready / too_many_items get their own toasts; approval_requested
carries item_count and phases.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Items model + pins by version set

**Files:**
- Modify: `src/components/client-lane/kv/kvItems.ts` (lines 110-120)
- Modify: `src/lib/client-lane/pins.ts` (whole file)
- Modify: `src/components/client-lane/DecisionPage.tsx` (lines 226-229 only — a bridge until Task 6)
- Create: `src/components/client-lane/kv/roundItems.ts`, `src/components/client-lane/kv/roundItems.test.ts`, `src/lib/client-lane/pins.test.ts`

**Interfaces:**
- Consumes: `approvalItemsOf` (Task 1), `itemLabel`/`kvItemPart` (`kvItems.ts`), `KV_SHARE_PHASES`/`KV_SHARE_PHASE_LABEL`.
- Produces:
  - `PagePin.version: string`; `pinsFromComments(comments: PublicComment[], versionIds: ReadonlySet<string> | null): PagePin[]`
  - `kvItemPart(item)` → `tile.{item.id}` for resize
  - `interface KvRoundItem { id: string; phase: KvSharePhase; versionId: string; caption: string; item: PublicKvItem; part: string; index: number }`
  - `kvRoundItems(data: Pick<ShareLinkKv, "items" | "document">): KvRoundItem[]`
  - `itemForPin(items: KvRoundItem[], pin: Pick<PagePin, "version">): KvRoundItem | null`
  - `interface PinGroup { key: string; label: string; pins: PagePin[] }`; `pinGroups(items: KvRoundItem[], pins: PagePin[]): PinGroup[]`

- [ ] **Step 1: Write the failing tests**

Create `src/lib/client-lane/pins.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { pinsFromComments } from "./pins";
import { pinComment } from "./testFixtures";

const onHero = pinComment("p1", "craft:g1:board.g1", "2026-09-30T08:00:00.000Z", {
  body: "Logo smaller",
});
const onFeed = pinComment("p2", "resize:r2:tile.r2", "2026-09-30T09:00:00.000Z", {
  body: "Crop tighter",
});
const earlierOnStory = pinComment(
  "p3",
  "resize:r1:tile.r1",
  "2026-09-30T07:00:00.000Z"
);
const onEarlierRound = pinComment(
  "p4",
  "craft:g0:board.g0",
  "2026-09-29T07:00:00.000Z"
);
const reply = pinComment("p5", "", "2026-09-30T08:30:00.000Z", {
  parent_id: "p1",
  anchor: null,
  body: "On it",
});

const ROUND = new Set(["g1", "r1", "r2"]);

describe("pinsFromComments", () => {
  it("keeps root pins on every item and numbers them across items by creation time", () => {
    const pins = pinsFromComments([onHero, onFeed, earlierOnStory], ROUND);
    expect(pins.map((p) => [p.id, p.number, p.version])).toEqual([
      ["p3", 1, "r1"],
      ["p1", 2, "g1"],
      ["p2", 3, "r2"],
    ]);
  });

  it("drops pins on versions outside the round", () => {
    const pins = pinsFromComments([onHero, onEarlierRound], ROUND);
    expect(pins.map((p) => p.id)).toEqual(["p1"]);
  });

  it("hangs replies under their pin instead of listing them as pins", () => {
    const [pin] = pinsFromComments([onHero, reply], ROUND);
    expect(pin.replies.map((r) => r.body)).toEqual(["On it"]);
  });

  it("keeps every pin when nothing scopes them", () => {
    expect(pinsFromComments([onHero, onEarlierRound], null)).toHaveLength(2);
  });
});
```

Create `src/components/client-lane/kv/roundItems.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import type { PagePin } from "@/lib/client-lane/pins";
import {
  CLIP,
  FEED,
  HERO,
  STORY,
  approvalItem,
  kvRound,
} from "@/lib/client-lane/testFixtures";

import { kvItemPart } from "./kvItems";
import { itemForPin, kvRoundItems, pinGroups } from "./roundItems";

function pinOn(version: string, number: number): PagePin {
  return {
    id: `p${number}`,
    number,
    stage: "craft",
    version,
    part: "x",
    x: 0.5,
    y: 0.5,
    author: "Dina",
    body: `Note ${number}`,
    createdAt: "2026-09-30T08:00:00.000Z",
    replies: [],
  };
}

describe("kvItemPart", () => {
  it("keys a resize tile by its row id, the editor's tile key (spec §5.3)", () => {
    expect(kvItemPart(STORY)).toBe("tile.r1");
  });

  it("keeps boards and motion clips as they were", () => {
    expect(kvItemPart(HERO)).toBe("board.g1");
    expect(kvItemPart(CLIP)).toBe("motion.m1");
  });
});

describe("kvRoundItems", () => {
  it("maps each frozen snapshot in round order", () => {
    const items = kvRoundItems(kvRound());
    expect(
      items.map((i) => [i.id, i.phase, i.versionId, i.part, i.index, i.caption])
    ).toEqual([
      ["ai_g1", "craft", "g1", "board.g1", 0, "Craft · Hero board"],
      ["ai_r1", "resize", "r1", "tile.r1", 1, "Resize · IG Story · 1080 × 1920"],
      ["ai_r2", "resize", "r2", "tile.r2", 2, "Resize · IG Feed · 1080 × 1080"],
    ]);
  });

  it("finds a backfilled item's artwork in the live payload by version id", () => {
    const [only] = kvRoundItems(
      kvRound({ items: [approvalItem(HERO, "craft", { snapshot: null })] })
    );
    expect(only.item).toBe(HERO);
  });

  it("skips an item with no artwork anywhere, and non-KV phases", () => {
    const items = kvRoundItems(
      kvRound({
        items: [
          approvalItem(HERO, "craft", { version_id: "gone", snapshot: null }),
          approvalItem(FEED, "deck", { snapshot: null, version_id: "dv1" }),
          approvalItem(STORY, "resize"),
        ],
      })
    );
    expect(items.map((i) => [i.id, i.index])).toEqual([["ai_r1", 0]]);
  });

  it("is empty for a view link", () => {
    expect(kvRoundItems(kvRound({ items: [] }))).toEqual([]);
  });
});

describe("itemForPin / pinGroups", () => {
  const items = kvRoundItems(kvRound());

  it("finds the item a pin sits on by version", () => {
    expect(itemForPin(items, { version: "r2" })?.id).toBe("ai_r2");
    expect(itemForPin(items, { version: "nope" })).toBeNull();
  });

  it("groups pins per item in round order and keeps strays visible", () => {
    const groups = pinGroups(items, [
      pinOn("r2", 1),
      pinOn("g1", 2),
      pinOn("r2", 3),
      pinOn("zz", 4),
    ]);
    expect(groups.map((g) => [g.label, g.pins.map((p) => p.number)])).toEqual([
      ["Craft · Hero board", [2]],
      ["Resize · IG Feed · 1080 × 1080", [1, 3]],
      ["Elsewhere in this round", [4]],
    ]);
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/pins.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/roundItems.test.ts
```

Expected: pins tests fail (`versionIds.has` is not a function / no `version` on pins); roundItems fails to resolve `./roundItems`.

- [ ] **Step 3: `kvItemPart` keys resize by row id**

Replace `kvItems.ts` lines 110-120 with:

```ts
/**
 * The pin anchor PART for a KV item, in the vocabulary the editor's own
 * adapter writes (`lib/studio/kv/kvCommentAdapter`): `board.{id}` on the
 * canvas, `tile.{resize row id}` in Resize, `motion.{id}` for a clip — so a
 * guest's pin lands on the same part the designer's would. Resize used
 * `tile.{platform_id}` in P0a; the editor keys tiles by ROW (a platform can
 * occupy several rows), so those early approval pins never landed on a tile
 * in the editor. The public page groups pins by VERSION, so they still show
 * on their item there (spec §5.3).
 */
export function kvItemPart(item: PublicKvItem): string {
  if (item.kind === "resize") return `tile.${item.id}`;
  if (item.kind === "motion") return `motion.${item.id}`;
  return `board.${item.id}`;
}
```

- [ ] **Step 4: Pins by version set**

Replace `src/lib/client-lane/pins.ts` with:

```ts
import { parsePinSpec } from "@/lib/comments/anchorCodec";

import type { PublicComment } from "./types";

/** A pin as the decision page draws and lists it (FR-37). */
export interface PagePin {
  id: string;
  /** 1-based, per ROUND across all of its items, in creation order. */
  number: number;
  stage: string;
  /** The anchor's version segment — which round item the pin sits on. */
  version: string;
  part: string;
  x: number;
  y: number;
  author: string;
  body: string;
  createdAt: string;
  /** Replies under the pin, oldest first. */
  replies: PublicComment[];
}

/**
 * Root pin comments on the round's items, numbered in creation order across
 * all of them. The api already scopes the list to the current round (C-4);
 * the version check is belt and braces so a stale cache can never renumber.
 * `versionIds === null` means nothing scopes the page (a live view link).
 */
export function pinsFromComments(
  comments: PublicComment[],
  versionIds: ReadonlySet<string> | null
): PagePin[] {
  const replies = new Map<string, PublicComment[]>();
  for (const c of comments) {
    if (c.parent_id) {
      const list = replies.get(c.parent_id) ?? [];
      list.push(c);
      replies.set(c.parent_id, list);
    }
  }

  const roots = comments
    .filter((c) => !c.parent_id && c.anchor?.kind === "pin")
    .map((c) => ({ c, spec: parsePinSpec(c.anchor?.id ?? "") }))
    .filter(
      ({ c, spec }) =>
        spec !== null &&
        (versionIds === null || versionIds.has(spec.version)) &&
        typeof c.anchor?.x === "number" &&
        typeof c.anchor?.y === "number"
    )
    .sort((a, b) => a.c.created_at.localeCompare(b.c.created_at));

  return roots.map(({ c, spec }, index) => ({
    id: c.id,
    number: index + 1,
    stage: spec!.stage,
    version: spec!.version,
    part: spec!.part,
    x: c.anchor!.x as number,
    y: c.anchor!.y as number,
    author: c.author?.name ?? "Guest",
    body: c.body,
    createdAt: c.created_at,
    replies: (replies.get(c.id) ?? []).sort((a, b) =>
      a.created_at.localeCompare(b.created_at)
    ),
  }));
}
```

- [ ] **Step 5: The items model**

Create `src/components/client-lane/kv/roundItems.ts`:

```ts
/**
 * The KV round as the decision page renders it (multi-item rounds, spec
 * §6.2) — replaces `lib/client-lane/kvTarget.ts`, which matched ONE item by
 * exact id and lost it whenever a board iterated.
 *
 * Artwork comes from the item's frozen `snapshot`; a backfilled round (no
 * snapshot) falls back to the live payload by `version_id`, and an item with
 * no artwork anywhere is skipped rather than drawn broken. Pure: no React.
 */
import type { PagePin } from "@/lib/client-lane/pins";
import { approvalItemsOf } from "@/lib/client-lane/round";
import type { ShareLinkKv } from "@/lib/client-lane/types";
import type { PublicKvItem, PublicKvResponse } from "@/services/query";
import {
  KV_SHARE_PHASE_LABEL,
  KV_SHARE_PHASES,
  type KvSharePhase,
} from "@/types/kv/share-link";

import { itemLabel, kvItemPart } from "./kvItems";

export interface KvRoundItem {
  /** `approval_items.id`. */
  id: string;
  phase: KvSharePhase;
  /** The rendered id — the version segment of every pin on this item. */
  versionId: string;
  /**
   * "Resize · IG Story · 1080 × 1920" — derived from the artwork, not the
   * api's `label`, because a backfilled item's label is only `v{round}`.
   */
  caption: string;
  item: PublicKvItem;
  /** The pin anchor part (`kvItemPart`). */
  part: string;
  /** 0-based position among the rendered items (round order). */
  index: number;
}

function isKvPhase(phase: string): phase is KvSharePhase {
  return (KV_SHARE_PHASES as readonly string[]).includes(phase);
}

function findInDocument(
  document: PublicKvResponse,
  id: string
): PublicKvItem | null {
  for (const phase of document.phases) {
    const hit = phase.items.find((item) => item.id === id);
    if (hit) return hit;
  }
  return null;
}

export function kvRoundItems(
  data: Pick<ShareLinkKv, "items" | "document">
): KvRoundItem[] {
  const out: KvRoundItem[] = [];
  for (const approvalItem of approvalItemsOf(data)) {
    if (!isKvPhase(approvalItem.phase)) continue;
    const item =
      approvalItem.snapshot ??
      findInDocument(data.document, approvalItem.version_id);
    if (!item) continue;
    out.push({
      id: approvalItem.id,
      phase: approvalItem.phase,
      versionId: approvalItem.version_id,
      caption: `${KV_SHARE_PHASE_LABEL[approvalItem.phase]} · ${itemLabel(item)}`,
      item,
      part: kvItemPart(item),
      index: out.length,
    });
  }
  return out;
}

export function itemForPin(
  items: KvRoundItem[],
  pin: Pick<PagePin, "version">
): KvRoundItem | null {
  return items.find((entry) => entry.versionId === pin.version) ?? null;
}

/** One `PinList` section: the pins on one item of the round. */
export interface PinGroup {
  key: string;
  label: string;
  pins: PagePin[];
}

/**
 * Pins grouped per item, in round order, items without pins omitted. A pin
 * whose version matches no rendered item (a backfilled item whose artwork is
 * gone) stays visible under its own heading rather than vanishing.
 */
export function pinGroups(items: KvRoundItem[], pins: PagePin[]): PinGroup[] {
  const groups: PinGroup[] = items
    .map((entry) => ({
      key: entry.id,
      label: entry.caption,
      pins: pins.filter((pin) => pin.version === entry.versionId),
    }))
    .filter((group) => group.pins.length > 0);
  const placed = new Set(items.map((entry) => entry.versionId));
  const strays = pins.filter((pin) => !placed.has(pin.version));
  if (strays.length > 0) {
    groups.push({ key: "__other__", label: "Elsewhere in this round", pins: strays });
  }
  return groups;
}
```

- [ ] **Step 6: Bridge the one caller**

`DecisionPage.tsx` lines 226-229 become (Task 6 replaces this):

```tsx
  const pins = useMemo<PagePin[]>(
    () =>
      pinsFromComments(
        comments,
        versionId === null ? null : new Set([versionId])
      ),
    [comments, versionId]
  );
```

- [ ] **Step 7: Run — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/pins.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/roundItems.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvShareBoardCanvas.test.tsx
```

- [ ] **Step 8: Mutation check**

(a) `kvItemPart` back to `platform_id` → first kvItemPart test fails; (b) drop the `versionIds.has` filter → "drops pins on versions outside" fails; (c) sort descending → numbering test fails; (d) in `kvRoundItems` use `approvalItem.snapshot` only (no document fallback) → backfilled test fails; (e) remove `if (!item) continue` → skip test throws/fails; (f) set `index: out.length + 1` → mapping test fails; (g) drop the strays push → grouping test fails.

- [ ] **Step 9: Format, lint, type-check, commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx prettier --write src/components/client-lane/kv/kvItems.ts src/components/client-lane/kv/roundItems.ts src/components/client-lane/kv/roundItems.test.ts src/lib/client-lane/pins.ts src/lib/client-lane/pins.test.ts src/components/client-lane/DecisionPage.tsx && bunx eslint src/components/client-lane/kv/kvItems.ts src/components/client-lane/kv/roundItems.ts src/components/client-lane/kv/roundItems.test.ts src/lib/client-lane/pins.ts src/lib/client-lane/pins.test.ts src/components/client-lane/DecisionPage.tsx && bunx tsc --noEmit -p . 2>&1 | grep -E "kv/(kvItems|roundItems)|client-lane/pins|DecisionPage"
```

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add src/components/client-lane/kv/kvItems.ts src/components/client-lane/kv/roundItems.ts src/components/client-lane/kv/roundItems.test.ts src/lib/client-lane/pins.ts src/lib/client-lane/pins.test.ts src/components/client-lane/DecisionPage.tsx && git commit -m "$(cat <<'EOF'
feat(web): items model for KV approval rounds; pins scoped by version set

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Grid building blocks — PinLayer numbering, swipe, KvPhaseGrid, KvLinkGallery

**Files:**
- Modify: `src/components/client-lane/PinLayer.tsx` (lines 20-41, 74-82)
- Modify: `src/components/client-lane/ui.ts` (append)
- Create: `src/components/client-lane/PinLayer.test.tsx`, `src/components/client-lane/kv/swipe.ts`, `src/components/client-lane/kv/swipe.test.ts`, `src/components/client-lane/kv/KvPhaseGrid.tsx`, `src/components/client-lane/kv/KvLinkGallery.tsx`, `src/components/client-lane/kv/KvLinkGallery.test.tsx`

**Interfaces:**
- Consumes: `KvItemArtwork`, `KvLightbox`, `itemLabel`, `sortForDisplay`, `FOCUS`.
- Produces:
  - `PinLayer` gains `draftNumber?: number`; root carries `data-client-lane-pin-layer`.
  - `PIN_FILL: string`
  - `SWIPE_MIN_PX = 48`; `swipeStep(dx: number, dy: number): -1 | 0 | 1`; `isTypingTarget(target: EventTarget | null): boolean`
  - `interface KvGridCard { key: string; item: PublicKvItem; caption: string; pinCount?: number }`; `interface KvGridPhase { phase: KvSharePhase; cards: KvGridCard[] }`
  - `KvPhaseGrid(props: { phases: KvGridPhase[]; activePhase: KvSharePhase | null; onPhaseChange: (phase: KvSharePhase) => void; onOpen: (card: KvGridCard, index: number) => void; openLabel: (card: KvGridCard) => string })`
  - `KvLinkGallery(props: { document: PublicKvResponse })`

- [ ] **Step 1: Write the failing tests**

Create `src/components/client-lane/PinLayer.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import type { PagePin } from "@/lib/client-lane/pins";

import { PinLayer } from "./PinLayer";

const one: PagePin = {
  id: "p1",
  number: 1,
  stage: "craft",
  version: "g1",
  part: "board.g1",
  x: 0.2,
  y: 0.2,
  author: "Dina",
  body: "Logo smaller",
  createdAt: "2026-09-30T08:00:00.000Z",
  replies: [],
};

function draftMarker(): string | null | undefined {
  return document.querySelector("[data-client-lane-pin-layer] span[aria-hidden]")
    ?.textContent;
}

describe("PinLayer draft numbering", () => {
  it("numbers the draft marker from draftNumber when given", () => {
    render(
      <PinLayer
        pins={[one]}
        draft={{ x: 0.5, y: 0.5 }}
        draftNumber={4}
        activeId={null}
        onSelect={() => {}}
      />
    );
    expect(draftMarker()).toBe("4");
  });

  it("falls back to one past the pins it draws", () => {
    render(
      <PinLayer
        pins={[one]}
        draft={{ x: 0.5, y: 0.5 }}
        activeId={null}
        onSelect={() => {}}
      />
    );
    expect(draftMarker()).toBe("2");
  });
});
```

Create `src/components/client-lane/kv/swipe.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { isTypingTarget, swipeStep } from "./swipe";

describe("swipeStep", () => {
  it("reads a leftward swipe as next and a rightward one as previous", () => {
    expect(swipeStep(-120, 10)).toBe(1);
    expect(swipeStep(120, -10)).toBe(-1);
  });

  it("ignores a tap-sized move", () => {
    expect(swipeStep(-20, 0)).toBe(0);
  });

  it("ignores a mostly vertical drag, which is a scroll", () => {
    expect(swipeStep(-60, 200)).toBe(0);
  });
});

describe("isTypingTarget", () => {
  it("is true for fields, editable regions and a focused video", () => {
    const editable = document.createElement("div");
    editable.contentEditable = "true";
    document.body.appendChild(editable);
    for (const el of [
      document.createElement("input"),
      document.createElement("textarea"),
      document.createElement("select"),
      document.createElement("video"),
      editable,
    ]) {
      expect(isTypingTarget(el)).toBe(true);
    }
    editable.remove();
  });

  it("is false for a button, the page and nothing", () => {
    expect(isTypingTarget(document.createElement("button"))).toBe(false);
    expect(isTypingTarget(document.body)).toBe(false);
    expect(isTypingTarget(null)).toBe(false);
  });
});
```

If `editable.isContentEditable` reads `false` in this DOM (it is a layout-free jsdom), print it once; the implementation below also checks the `contenteditable` attribute so the test stays meaningful either way.

Create `src/components/client-lane/kv/KvLinkGallery.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { render, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";

import { kvRound } from "@/lib/client-lane/testFixtures";

import { KvLinkGallery } from "./KvLinkGallery";

const body = () => within(document.body);

describe("KvLinkGallery", () => {
  it("draws each stage as a tab over a grid and opens the full-size viewer", async () => {
    const user = userEvent.setup();
    render(<KvLinkGallery document={kvRound().document} />);

    expect(body().getByRole("button", { name: "Craft" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(
      body().getByRole("button", { name: "Open Hero board full size" })
    ).toBeInTheDocument();

    await user.click(body().getByRole("button", { name: "Resize" }));
    await user.click(
      body().getByRole("button", {
        name: "Open IG Story · 1080 × 1920 full size",
      })
    );

    expect(
      body().getByRole("dialog", { name: "IG Story · 1080 × 1920" })
    ).toBeInTheDocument();
  });

  it("renders nothing when no stage has anything in it", () => {
    const { container } = render(
      <KvLinkGallery
        document={{
          name: "Empty",
          brand_slug: "garuda",
          phases: [{ phase: "craft", items: [] }],
        }}
      />
    );
    expect(container.firstChild).toBeNull();
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/PinLayer.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/swipe.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvLinkGallery.test.tsx
```

Expected: PinLayer first test gets `"2"` (no `draftNumber`) and `document.querySelector` finds nothing (no data attribute); the other two fail to resolve their modules.

- [ ] **Step 3: PinLayer**

In `PinLayer.tsx`, the props block (lines 20-33) becomes:

```tsx
export function PinLayer({
  pins,
  draft,
  draftNumber,
  activeId,
  onPlace,
  onSelect,
}: {
  pins: PagePin[];
  draft: PinDraft | null;
  /**
   * The number the unsaved pin will get. Pins are numbered per ROUND, so a
   * layer drawing one item's pins cannot derive it; defaults to one past the
   * pins drawn here (a deck slide keeps its P0a behaviour).
   */
  draftNumber?: number;
  activeId: string | null;
  /** Absent → read-only: markers show, taps do nothing. */
  onPlace?: (x: number, y: number) => void;
  onSelect: (id: string | null) => void;
}) {
```

The root `<div` (line 37) gains the attribute as its first prop:

```tsx
    <div
      data-client-lane-pin-layer=""
```

Line 80 (`{pins.length + 1}`) becomes:

```tsx
          {draftNumber ?? pins.length + 1}
```

- [ ] **Step 4: `ui.ts` pin fill**

Append to `src/components/client-lane/ui.ts`:

```ts

/** The pin marker's amber — the same fill `PinLayer` and `PinList` draw. */
export const PIN_FILL = "bg-[#F5B800] text-black";
```

- [ ] **Step 5: `swipe.ts`**

Create `src/components/client-lane/kv/swipe.ts`:

```ts
/** Horizontal travel (px) before a touch counts as a swipe, not a tap. */
export const SWIPE_MIN_PX = 48;

/**
 * −1 / +1 for a horizontal swipe (left = next), 0 for a tap or a mostly
 * vertical drag — that one is the page scrolling, not a request to step.
 */
export function swipeStep(dx: number, dy: number): -1 | 0 | 1 {
  if (Math.abs(dx) < SWIPE_MIN_PX) return 0;
  if (Math.abs(dx) < Math.abs(dy) * 1.5) return 0;
  return dx < 0 ? 1 : -1;
}

/**
 * Where ←/→ belong to the element, not the gallery: a text field (the pin
 * note, the name gate), an editable region, or a focused `<video controls>`,
 * which already maps the arrows to seeking.
 */
export function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName;
  if (
    tag === "INPUT" ||
    tag === "TEXTAREA" ||
    tag === "SELECT" ||
    tag === "VIDEO"
  ) {
    return true;
  }
  return (
    target.isContentEditable ||
    target.getAttribute("contenteditable") === "true"
  );
}
```

- [ ] **Step 6: `KvPhaseGrid.tsx`**

Create `src/components/client-lane/kv/KvPhaseGrid.tsx`:

```tsx
"use client";

import type { PublicKvItem } from "@/services/query";
import {
  KV_SHARE_PHASE_LABEL,
  type KvSharePhase,
} from "@/types/kv/share-link";

import { FOCUS, PIN_FILL } from "../ui";
import { KvItemArtwork } from "./KvItemArtwork";

export interface KvGridCard {
  /** React key and the caller's handle back to its own model. */
  key: string;
  item: PublicKvItem;
  caption: string;
  /** Pins on this item — drawn as a badge when > 0. */
  pinCount?: number;
}

export interface KvGridPhase {
  phase: KvSharePhase;
  cards: KvGridCard[];
}

/**
 * Stage tabs over a grid of cards — the look the view-link share page drew
 * (lifted from the P0a `KvHero` gallery), shared by the view-link gallery and
 * the approval round's gallery so the two cannot drift.
 */
export function KvPhaseGrid({
  phases,
  activePhase,
  onPhaseChange,
  onOpen,
  openLabel,
}: {
  phases: KvGridPhase[];
  activePhase: KvSharePhase | null;
  onPhaseChange: (phase: KvSharePhase) => void;
  onOpen: (card: KvGridCard, index: number) => void;
  /** Accessible name for a card's button. */
  openLabel: (card: KvGridCard) => string;
}) {
  const current =
    phases.find((p) => p.phase === activePhase) ?? phases[0] ?? null;

  return (
    <div className="flex flex-col gap-3">
      {phases.length > 1 && (
        <nav aria-label="Phases" className="flex flex-wrap gap-1">
          {phases.map(({ phase }) => (
            <button
              key={phase}
              type="button"
              onClick={() => onPhaseChange(phase)}
              aria-current={phase === current?.phase ? "page" : undefined}
              className={[
                "min-h-[40px] rounded-full px-4 font-geist text-[13px] transition-colors",
                phase === current?.phase
                  ? "bg-white/15 text-white"
                  : "text-white/50 hover:bg-white/5",
                FOCUS,
              ].join(" ")}
            >
              {KV_SHARE_PHASE_LABEL[phase]}
            </button>
          ))}
        </nav>
      )}

      {current === null || current.cards.length === 0 ? (
        <p className="font-geist text-[13px] text-white/40">
          This phase is being updated. Check back soon.
        </p>
      ) : (
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
          {current.cards.map((card, index) => (
            <figure key={card.key} className="min-w-0">
              <button
                type="button"
                onClick={() => onOpen(card, index)}
                aria-label={openLabel(card)}
                className={`relative block h-36 w-full cursor-zoom-in overflow-hidden rounded-xl border border-white/10 bg-white/5 transition-colors hover:border-white/25 sm:h-44 ${FOCUS}`}
              >
                <KvItemArtwork
                  item={card.item}
                  className="h-full w-full object-contain"
                />
                {card.pinCount ? (
                  <span
                    aria-hidden
                    className={`pointer-events-none absolute right-2 top-2 flex h-6 min-w-[24px] items-center justify-center rounded-full px-1.5 font-geist text-[11px] font-semibold shadow-[0_2px_8px_rgba(0,0,0,0.5)] ${PIN_FILL}`}
                  >
                    {card.pinCount}
                  </span>
                ) : null}
              </button>
              <figcaption className="mt-1.5 flex items-center gap-2">
                <span className="truncate font-geist text-[12px] text-white/60">
                  {card.caption}
                </span>
                {card.item.kind === "board" && card.item.is_master && (
                  <span className="rounded-full border border-white/15 px-1.5 py-px font-geist text-[9px] font-medium uppercase tracking-wide text-white/50">
                    Master
                  </span>
                )}
              </figcaption>
            </figure>
          ))}
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 7: `KvLinkGallery.tsx`**

Create `src/components/client-lane/kv/KvLinkGallery.tsx`:

```tsx
"use client";

import { useCallback, useEffect, useMemo, useState } from "react";

import type { PublicKvResponse } from "@/services/query";
import type { KvSharePhase } from "@/types/kv/share-link";

import { KvLightbox } from "./KvLightbox";
import { KvPhaseGrid, type KvGridPhase } from "./KvPhaseGrid";
import { itemLabel, sortForDisplay } from "./kvItems";

/**
 * A `view` link's hero: stage tabs over a grid, tap for the full-size viewer
 * — the gallery the retired `/share/[token]` page drew. Also the fallback for
 * a backfilled round whose one live item is gone (nothing frozen to focus).
 */
export function KvLinkGallery({ document }: { document: PublicKvResponse }) {
  const phases = useMemo<KvGridPhase[]>(
    () =>
      document.phases
        .filter((p) => p.items.length > 0)
        .map((p) => ({
          phase: p.phase,
          cards: sortForDisplay(p.phase, p.items).map((item) => ({
            key: item.id,
            item,
            caption: itemLabel(item),
          })),
        })),
    [document]
  );
  const [activePhase, setActivePhase] = useState<KvSharePhase | null>(
    phases[0]?.phase ?? null
  );
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  const current =
    phases.find((p) => p.phase === activePhase) ?? phases[0] ?? null;

  useEffect(() => {
    setLightboxIndex(null);
  }, [activePhase]);

  const stepLightbox = useCallback(
    (delta: number) => {
      setLightboxIndex((prev) => {
        const count = current?.cards.length ?? 0;
        if (prev === null || count === 0) return prev;
        return (prev + delta + count) % count;
      });
    },
    [current?.cards.length]
  );

  if (phases.length === 0) return null;

  const lightboxCard =
    lightboxIndex === null ? null : (current?.cards[lightboxIndex] ?? null);

  return (
    <div className="flex flex-col gap-3">
      <KvPhaseGrid
        phases={phases}
        activePhase={current?.phase ?? null}
        onPhaseChange={setActivePhase}
        onOpen={(_card, index) => setLightboxIndex(index)}
        openLabel={(card) => `Open ${card.caption} full size`}
      />
      {lightboxCard && (
        <KvLightbox
          item={lightboxCard.item}
          index={lightboxIndex as number}
          total={current?.cards.length ?? 0}
          onClose={() => setLightboxIndex(null)}
          onStep={stepLightbox}
        />
      )}
    </div>
  );
}
```

- [ ] **Step 8: Run — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/PinLayer.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/swipe.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvLinkGallery.test.tsx
```

- [ ] **Step 9: Mutation check**

(a) PinLayer ignores `draftNumber` → first PinLayer test fails; (b) `swipeStep` drops the vertical guard → "mostly vertical" fails; (c) `swipeStep` returns `dx < 0 ? -1 : 1` → direction test fails; (d) `isTypingTarget` drops `"TEXTAREA"` → field test fails; (e) `KvLinkGallery` stops filtering empty phases → "renders nothing" fails; (f) `openLabel` in `KvLinkGallery` drops " full size" → the gallery test fails.

- [ ] **Step 10: Format, lint, type-check, commit**

The shell here is zsh, which does not word-split `$VAR` — list the files literally.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx prettier --write src/components/client-lane/PinLayer.tsx src/components/client-lane/PinLayer.test.tsx src/components/client-lane/ui.ts src/components/client-lane/kv/swipe.ts src/components/client-lane/kv/swipe.test.ts src/components/client-lane/kv/KvPhaseGrid.tsx src/components/client-lane/kv/KvLinkGallery.tsx src/components/client-lane/kv/KvLinkGallery.test.tsx && bunx eslint src/components/client-lane/PinLayer.tsx src/components/client-lane/PinLayer.test.tsx src/components/client-lane/ui.ts src/components/client-lane/kv/swipe.ts src/components/client-lane/kv/swipe.test.ts src/components/client-lane/kv/KvPhaseGrid.tsx src/components/client-lane/kv/KvLinkGallery.tsx src/components/client-lane/kv/KvLinkGallery.test.tsx && bunx tsc --noEmit -p . 2>&1 | grep -E "client-lane/(PinLayer|ui|kv/(swipe|KvPhaseGrid|KvLinkGallery))"
```

Expected: the grep prints nothing.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add src/components/client-lane/PinLayer.tsx src/components/client-lane/PinLayer.test.tsx src/components/client-lane/ui.ts src/components/client-lane/kv/swipe.ts src/components/client-lane/kv/swipe.test.ts src/components/client-lane/kv/KvPhaseGrid.tsx src/components/client-lane/kv/KvLinkGallery.tsx src/components/client-lane/kv/KvLinkGallery.test.tsx && git commit -m "$(cat <<'EOF'
feat(web): KV phase grid, link gallery, swipe helpers, round-wide draft number

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Focused view + round hero

**Files:**
- Modify: `src/lib/analytics/client-lane-events.ts` (append to the public-side block, after line 163)
- Create: `src/components/client-lane/kv/KvFocusedItem.tsx`, `src/components/client-lane/kv/KvRoundHero.tsx`, `src/components/client-lane/kv/KvRoundHero.test.tsx`

**Interfaces:**
- Consumes: `KvRoundItem`, `kvRoundItems` (Task 3); `KvPhaseGrid`, `PinLayer.draftNumber`, `swipeStep`, `isTypingTarget`, `PIN_FILL` (Task 4); `PagePin.version`.
- Produces:
  - `trackClientGalleryItemOpened(props: { phase: KvSharePhase; index: number }): void` → `client_lane.gallery_item_opened`
  - `KvFocusedItem(props: { entry: KvRoundItem; total: number; pins: PagePin[]; draft: PinDraft | null; draftNumber: number; activePinId: string | null; keyboardEnabled: boolean; onStep?: (delta: 1 | -1) => void; onBack?: () => void; onPlacePin?: (x: number, y: number) => void; onSelectPin: (id: string | null) => void })`
  - `interface KvRoundHeroProps { items: KvRoundItem[]; pins: PagePin[]; draft: { version: string; x: number; y: number } | null; activePinId: string | null; focusedId: string | null; onFocusChange: (id: string | null) => void; keyboardEnabled: boolean; onPlacePin?: (item: KvRoundItem, x: number, y: number) => void; onSelectPin: (id: string | null) => void }`; `KvRoundHero(props: KvRoundHeroProps)`

- [ ] **Step 1: Write the failing tests**

Create `src/components/client-lane/kv/KvRoundHero.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { fireEvent, render, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { PagePin } from "@/lib/client-lane/pins";
import { kvRound } from "@/lib/client-lane/testFixtures";

import { KvRoundHero, type KvRoundHeroProps } from "./KvRoundHero";
import { kvRoundItems } from "./roundItems";

const body = () => within(document.body);
const items = kvRoundItems(kvRound());

function pin(id: string, number: number, version: string, text = `Note ${number}`): PagePin {
  return {
    id,
    number,
    stage: "craft",
    version,
    part: "x",
    x: 0.5,
    y: 0.5,
    author: "Dina",
    body: text,
    createdAt: "2026-09-30T08:00:00.000Z",
    replies: [],
  };
}

const onFocus = vi.fn();

/** Controlled the way DecisionPage drives it — a stubbed onFocusChange would
 *  make every focus assertion vacuous. */
function Harness(props: Partial<KvRoundHeroProps>) {
  const [focusedId, setFocusedId] = useState<string | null>(
    props.focusedId ?? null
  );
  return (
    <>
      <input aria-label="Elsewhere" />
      <KvRoundHero
        items={items}
        pins={[]}
        draft={null}
        activePinId={null}
        keyboardEnabled
        onSelectPin={() => {}}
        {...props}
        focusedId={focusedId}
        onFocusChange={(id) => {
          onFocus(id);
          setFocusedId(id);
        }}
      />
    </>
  );
}

beforeEach(() => {
  vi.restoreAllMocks();
  onFocus.mockClear();
});

describe("KvRoundHero — gallery", () => {
  it("shows stage tabs over a grid, each card carrying its pin count", async () => {
    const user = userEvent.setup();
    render(<Harness pins={[pin("p1", 1, "r2"), pin("p2", 2, "r2")]} />);

    expect(body().getByRole("button", { name: "Craft" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(
      body().getByRole("button", { name: "Open Hero board" })
    ).toBeInTheDocument();

    await user.click(body().getByRole("button", { name: "Resize" }));
    expect(
      body().getByRole("button", { name: "Open IG Story · 1080 × 1920" })
    ).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Open IG Feed · 1080 × 1080 · 2 pins" })
    ).toBeInTheDocument();
  });

  it("opens a tapped card as the focused view and reports which one", async () => {
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const user = userEvent.setup();
    render(<Harness />);

    await user.click(body().getByRole("button", { name: "Resize" }));
    await user.click(
      body().getByRole("button", { name: "Open IG Story · 1080 × 1920" })
    );

    expect(
      body().getByText("Resize · IG Story · 1080 × 1920")
    ).toBeInTheDocument();
    expect(body().getByText("2/3")).toBeInTheDocument();
    expect(onFocus).toHaveBeenLastCalledWith("ai_r1");
    expect(capture).toHaveBeenCalledWith(
      "client_lane.gallery_item_opened",
      expect.objectContaining({ phase: "resize", index: 1 })
    );
  });
});

describe("KvRoundHero — focused view", () => {
  it("steps with ← and → across stages, wrapping at both ends", async () => {
    const user = userEvent.setup();
    render(<Harness focusedId="ai_g1" />);

    expect(body().getByText("Craft · Hero board")).toBeInTheDocument();
    await user.keyboard("{ArrowLeft}");
    expect(
      body().getByText("Resize · IG Feed · 1080 × 1080")
    ).toBeInTheDocument();
    await user.keyboard("{ArrowRight}");
    await user.keyboard("{ArrowRight}");
    expect(
      body().getByText("Resize · IG Story · 1080 × 1920")
    ).toBeInTheDocument();
  });

  it("ignores arrow keys typed into a field", async () => {
    const user = userEvent.setup();
    render(<Harness focusedId="ai_g1" />);

    await user.click(body().getByLabelText("Elsewhere"));
    await user.keyboard("{ArrowRight}");

    expect(body().getByText("1/3")).toBeInTheDocument();
  });

  it("ignores arrow keys while keyboard stepping is off (a sheet is open)", async () => {
    const user = userEvent.setup();
    render(<Harness focusedId="ai_g1" keyboardEnabled={false} />);

    await user.keyboard("{ArrowRight}");

    expect(body().getByText("1/3")).toBeInTheDocument();
  });

  it("steps on a horizontal swipe but not on a vertical scroll", () => {
    render(<Harness focusedId="ai_g1" />);
    const figure = body()
      .getByText("Craft · Hero board")
      .closest("figure") as HTMLElement;

    fireEvent.touchStart(figure, { touches: [{ clientX: 200, clientY: 100 }] });
    fireEvent.touchEnd(figure, {
      changedTouches: [{ clientX: 190, clientY: 300 }],
    });
    expect(body().getByText("1/3")).toBeInTheDocument();

    fireEvent.touchStart(figure, { touches: [{ clientX: 200, clientY: 100 }] });
    fireEvent.touchEnd(figure, {
      changedTouches: [{ clientX: 80, clientY: 110 }],
    });
    expect(body().getByText("2/3")).toBeInTheDocument();
  });

  it("goes back to the grid on the focused item's own stage", async () => {
    const user = userEvent.setup();
    render(<Harness focusedId="ai_r1" />);

    await user.click(body().getByRole("button", { name: /All 3 items/ }));

    expect(onFocus).toHaveBeenLastCalledWith(null);
    expect(body().getByRole("button", { name: "Resize" })).toHaveAttribute(
      "aria-current",
      "page"
    );
  });

  it("draws only this item's pins and numbers a new draft after the whole round", () => {
    render(
      <Harness
        focusedId="ai_r1"
        pins={[pin("p1", 1, "g1"), pin("p2", 2, "r2")]}
        draft={{ version: "r1", x: 0.3, y: 0.3 }}
      />
    );

    expect(body().queryByRole("button", { name: /^Pin \d/ })).toBeNull();
    expect(
      document.querySelector("[data-client-lane-pin-layer] span[aria-hidden]")
        ?.textContent
    ).toBe("3");
  });

  it("hides a draft that belongs to another item", () => {
    render(<Harness focusedId="ai_r1" draft={{ version: "g1", x: 0.3, y: 0.3 }} />);

    expect(
      document.querySelector("[data-client-lane-pin-layer] span[aria-hidden]")
    ).toBeNull();
  });

  it("hands the focused item and the tapped spot to onPlacePin", () => {
    const onPlacePin = vi.fn();
    render(<Harness focusedId="ai_r1" onPlacePin={onPlacePin} />);
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

    fireEvent.click(layer, { clientX: 50, clientY: 50 });

    expect(onPlacePin).toHaveBeenCalledWith(
      expect.objectContaining({
        id: "ai_r1",
        phase: "resize",
        versionId: "r1",
        part: "tile.r1",
      }),
      0.25,
      0.5
    );
  });

  it("opens a one-item round straight in the focused view, with nowhere to step", () => {
    render(<Harness items={[items[0]]} />);

    expect(body().getByText("Craft · Hero board")).toBeInTheDocument();
    expect(body().queryByRole("button", { name: /All \d+ items/ })).toBeNull();
    expect(body().queryByRole("button", { name: "Next item" })).toBeNull();
    expect(body().queryByRole("navigation", { name: "Phases" })).toBeNull();
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvRoundHero.test.tsx
```

Expected: cannot resolve `./KvRoundHero`.

- [ ] **Step 3: Analytics helper**

Append to the public-side block of `src/lib/analytics/client-lane-events.ts` (after `trackClientPinFailed`, line 163):

```ts

/**
 * A card in a round's gallery was opened into the focused view — whether
 * clients actually browse the set (spec §7). Grid taps only; ←/→ stepping
 * inside the focused view is not an "open".
 */
export const trackClientGalleryItemOpened = (props: {
  phase: KvSharePhase;
  /** 0-based position of the item in the round. */
  index: number;
}) => safeCapture("client_lane.gallery_item_opened", props);
```

(`KvSharePhase` is already imported since Task 2.)

- [ ] **Step 4: `KvFocusedItem.tsx`**

Create `src/components/client-lane/kv/KvFocusedItem.tsx`:

```tsx
"use client";

import { useEffect, useRef } from "react";
import { CaretLeft, CaretRight } from "@phosphor-icons/react";

import type { PagePin } from "@/lib/client-lane/pins";

import { PinLayer, type PinDraft } from "../PinLayer";
import { BTN_GHOST, FOCUS } from "../ui";
import { KvItemArtwork } from "./KvItemArtwork";
import type { KvRoundItem } from "./roundItems";
import { isTypingTarget, swipeStep } from "./swipe";

const STEP_BUTTON = `flex h-11 w-11 items-center justify-center rounded-full text-white/60 transition-colors hover:bg-white/10 hover:text-white ${FOCUS}`;

/**
 * One round item, large, with the pin layer on its own box (FR-37 on ANY
 * item). ← / → and a horizontal swipe step through the round; Escape and
 * "All n items" go back to the grid. Inline rather than an overlay so the
 * decision bar and the sheets keep their stacking on a phone.
 */
export function KvFocusedItem({
  entry,
  total,
  pins,
  draft,
  draftNumber,
  activePinId,
  keyboardEnabled,
  onStep,
  onBack,
  onPlacePin,
  onSelectPin,
}: {
  entry: KvRoundItem;
  total: number;
  /** This item's pins only (numbers stay round-wide). */
  pins: PagePin[];
  draft: PinDraft | null;
  /** The round-wide number the next pin gets. */
  draftNumber: number;
  activePinId: string | null;
  /** False while a sheet is open. */
  keyboardEnabled: boolean;
  /** Absent for a one-item round. */
  onStep?: (delta: 1 | -1) => void;
  /** Absent for a one-item round (there is no grid to go back to). */
  onBack?: () => void;
  onPlacePin?: (x: number, y: number) => void;
  onSelectPin: (id: string | null) => void;
}) {
  const touchStart = useRef<{ x: number; y: number } | null>(null);

  useEffect(() => {
    if (!keyboardEnabled || (!onStep && !onBack)) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || isTypingTarget(e.target)) return;
      if (e.key === "ArrowRight" && onStep) {
        e.preventDefault();
        onStep(1);
      } else if (e.key === "ArrowLeft" && onStep) {
        e.preventDefault();
        onStep(-1);
      } else if (e.key === "Escape" && onBack) {
        onBack();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [keyboardEnabled, onStep, onBack]);

  return (
    <figure
      className="flex flex-col gap-2"
      onTouchStart={(e) => {
        const t = e.touches[0];
        touchStart.current = t ? { x: t.clientX, y: t.clientY } : null;
      }}
      onTouchEnd={(e) => {
        const start = touchStart.current;
        touchStart.current = null;
        const t = e.changedTouches[0];
        if (!start || !t || !onStep) return;
        const step = swipeStep(t.clientX - start.x, t.clientY - start.y);
        if (step !== 0) onStep(step);
      }}
    >
      {(onBack || onStep) && (
        <div className="flex items-center justify-between gap-2">
          {onBack ? (
            <button
              type="button"
              onClick={onBack}
              className={`${BTN_GHOST} -ml-3 ${FOCUS}`}
            >
              <CaretLeft size={16} aria-hidden />
              All {total} items
            </button>
          ) : (
            <span />
          )}
          {onStep && (
            <span className="flex items-center gap-1">
              <button
                type="button"
                aria-label="Previous item"
                onClick={() => onStep(-1)}
                className={STEP_BUTTON}
              >
                <CaretLeft size={20} />
              </button>
              <span
                aria-live="polite"
                className="min-w-[36px] text-center font-mono text-[12px] text-white/40"
              >
                {entry.index + 1}/{total}
              </span>
              <button
                type="button"
                aria-label="Next item"
                onClick={() => onStep(1)}
                className={STEP_BUTTON}
              >
                <CaretRight size={20} />
              </button>
            </span>
          )}
        </div>
      )}

      <div
        className="relative mx-auto w-fit max-w-full overflow-hidden rounded-xl bg-white/[0.03]"
        data-client-lane-stage
      >
        <KvItemArtwork
          key={entry.id}
          item={entry.item}
          controls
          className="block max-h-[calc(100svh-240px)] w-auto max-w-full object-contain sm:max-h-[70vh]"
        />
        <PinLayer
          pins={pins}
          draft={draft}
          draftNumber={draftNumber}
          activeId={activePinId}
          onPlace={onPlacePin}
          onSelect={onSelectPin}
        />
      </div>

      <figcaption className="flex items-center justify-between gap-2 font-geist text-[13px] text-white/60">
        <span className="truncate">{entry.caption}</span>
        {onPlacePin && (
          <span className="hidden shrink-0 text-[12px] text-white/40 sm:inline">
            Tap the image to pin a note
          </span>
        )}
      </figcaption>
    </figure>
  );
}
```

- [ ] **Step 5: `KvRoundHero.tsx`**

Create `src/components/client-lane/kv/KvRoundHero.tsx`:

```tsx
"use client";

import { useCallback, useMemo, useState } from "react";

import { trackClientGalleryItemOpened } from "@/lib/analytics/client-lane-events";
import type { PagePin } from "@/lib/client-lane/pins";
import type { KvSharePhase } from "@/types/kv/share-link";

import { KvFocusedItem } from "./KvFocusedItem";
import { KvPhaseGrid, type KvGridCard, type KvGridPhase } from "./KvPhaseGrid";
import { itemLabel } from "./kvItems";
import type { KvRoundItem } from "./roundItems";

export interface KvRoundHeroProps {
  /** The round's items in round order — never empty (KvHero routes `[]` to
   *  the link gallery). */
  items: KvRoundItem[];
  /** Every pin on the round, numbered round-wide. */
  pins: PagePin[];
  /** An unsaved pin and the item (version) it sits on. */
  draft: { version: string; x: number; y: number } | null;
  activePinId: string | null;
  /** Controlled: the item in the focused view; `null` = the grid. */
  focusedId: string | null;
  onFocusChange: (id: string | null) => void;
  /** False while a sheet is open, so ←/→ in a note never changes item. */
  keyboardEnabled: boolean;
  /** Absent → pins are read-only. */
  onPlacePin?: (item: KvRoundItem, x: number, y: number) => void;
  onSelectPin: (id: string | null) => void;
}

/**
 * A KV approval round (spec §6.2): stage tabs + grid with a pin badge per
 * card; a tapped card opens the focused view with pins on that item. A
 * one-item round opens straight in the focused view — P0a's look.
 */
export function KvRoundHero({
  items,
  pins,
  draft,
  activePinId,
  focusedId,
  onFocusChange,
  keyboardEnabled,
  onPlacePin,
  onSelectPin,
}: KvRoundHeroProps) {
  const single = items.length === 1;
  const focused = single
    ? items[0]
    : (items.find((entry) => entry.id === focusedId) ?? null);
  const [activePhase, setActivePhase] = useState<KvSharePhase | null>(
    items[0]?.phase ?? null
  );

  const phases = useMemo<KvGridPhase[]>(() => {
    const count = new Map<string, number>();
    for (const p of pins) count.set(p.version, (count.get(p.version) ?? 0) + 1);
    const out: KvGridPhase[] = [];
    for (const entry of items) {
      let group = out.find((g) => g.phase === entry.phase);
      if (!group) {
        group = { phase: entry.phase, cards: [] };
        out.push(group);
      }
      group.cards.push({
        key: entry.id,
        item: entry.item,
        caption: itemLabel(entry.item),
        pinCount: count.get(entry.versionId) ?? 0,
      });
    }
    return out;
  }, [items, pins]);

  const open = (card: KvGridCard) => {
    const entry = items.find((i) => i.id === card.key);
    if (!entry) return;
    trackClientGalleryItemOpened({ phase: entry.phase, index: entry.index });
    onFocusChange(entry.id);
  };

  const step = useCallback(
    (delta: 1 | -1) => {
      if (!focused) return;
      const at = items.indexOf(focused);
      const next = items[(at + delta + items.length) % items.length];
      setActivePhase(next.phase);
      onFocusChange(next.id);
    },
    [focused, items, onFocusChange]
  );

  const back = useCallback(() => {
    if (focused) setActivePhase(focused.phase);
    onFocusChange(null);
  }, [focused, onFocusChange]);

  if (focused) {
    return (
      <KvFocusedItem
        entry={focused}
        total={items.length}
        pins={pins.filter((p) => p.version === focused.versionId)}
        draft={
          draft && draft.version === focused.versionId
            ? { x: draft.x, y: draft.y }
            : null
        }
        draftNumber={pins.length + 1}
        activePinId={activePinId}
        keyboardEnabled={keyboardEnabled}
        onStep={single ? undefined : step}
        onBack={single ? undefined : back}
        onPlacePin={
          onPlacePin ? (x, y) => onPlacePin(focused, x, y) : undefined
        }
        onSelectPin={onSelectPin}
      />
    );
  }

  return (
    <section aria-label="Items in this round" className="flex flex-col gap-3">
      <p className="font-geist text-[12px] text-white/45">
        Tap an item to see it large{onPlacePin ? " and pin a note on it" : ""}.
      </p>
      <KvPhaseGrid
        phases={phases}
        activePhase={activePhase}
        onPhaseChange={setActivePhase}
        onOpen={open}
        openLabel={(card) =>
          card.pinCount
            ? `Open ${card.caption} · ${card.pinCount} ${card.pinCount === 1 ? "pin" : "pins"}`
            : `Open ${card.caption}`
        }
      />
    </section>
  );
}
```

- [ ] **Step 6: Run — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvRoundHero.test.tsx
```

- [ ] **Step 7: Mutation check**

(a) drop `isTypingTarget(e.target)` → "ignores arrow keys typed into a field" fails; (b) ignore `keyboardEnabled` in the effect → "…keyboard stepping is off" fails; (c) `draftNumber={pins.filter(p => p.version === focused.versionId).length + 1}` → "numbers a new draft after the whole round" fails; (d) pass `draft` unfiltered → "hides a draft that belongs to another item" fails; (e) `back` without `setActivePhase(focused.phase)` → "goes back … own stage" fails; (f) `step` without the `% items.length` wrap → wrapping test fails; (g) remove `trackClientGalleryItemOpened` → "opens a tapped card…" fails; (h) swap the `swipeStep` args → swipe test fails; (i) `single` computed as `false` → one-item test fails.

- [ ] **Step 8: Format, lint, type-check, commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx prettier --write src/lib/analytics/client-lane-events.ts src/components/client-lane/kv/KvFocusedItem.tsx src/components/client-lane/kv/KvRoundHero.tsx src/components/client-lane/kv/KvRoundHero.test.tsx && bunx eslint src/lib/analytics/client-lane-events.ts src/components/client-lane/kv/KvFocusedItem.tsx src/components/client-lane/kv/KvRoundHero.tsx src/components/client-lane/kv/KvRoundHero.test.tsx && bunx tsc --noEmit -p . 2>&1 | grep -E "client-lane-events|kv/(KvFocusedItem|KvRoundHero)"
```

Expected: the grep prints nothing.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add src/lib/analytics/client-lane-events.ts src/components/client-lane/kv/KvFocusedItem.tsx src/components/client-lane/kv/KvRoundHero.tsx src/components/client-lane/kv/KvRoundHero.test.tsx && git commit -m "$(cat <<'EOF'
feat(web): KV round hero — gallery with pin badges and a focused view

Pins on any item, ←/→ and swipe between items, round-wide pin numbering,
client_lane.gallery_item_opened.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: DecisionPage integration

**Files:**
- Rewrite: `src/components/client-lane/hero/KvHero.tsx`
- Modify: `src/components/client-lane/PinList.tsx` (lines 1-5, 12-82)
- Modify: `src/components/client-lane/DecisionBar.tsx` (lines 12-26, 42)
- Modify: `src/lib/analytics/client-lane-events.ts` (lines 127-136, 153-156)
- Modify: `src/components/client-lane/DecisionPage.tsx` (lines 22-26, 36-41, 53, 90-94, 117-147, 172-176, 226-229, 304-312, 367, 413-531, 533-567, 617-628, 637-645, 680-698)
- Delete: `src/lib/client-lane/kvTarget.ts`
- Create: `src/components/client-lane/DecisionPage.test.tsx`

**Interfaces:**
- Consumes: everything from Tasks 1, 3, 4, 5.
- Produces:
  - `KvHero(props: KvRoundHeroProps & { document: PublicKvResponse })`
  - `PinList` gains `groups?: PinGroup[]`
  - `DecisionBar` prop `approveLabel: string` replaces `versionLabel`
  - `trackClientDecisionSubmitted` props gain `item_count: number`; `trackClientPinPlaced` props gain `phase: ApprovalItemPhase`

- [ ] **Step 1: Write the failing page tests**

Create `src/components/client-lane/DecisionPage.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  HERO,
  approvalItem,
  kvRound,
  pendingApproval,
  pinComment,
} from "@/lib/client-lane/testFixtures";
import type {
  ApprovalDecision,
  PublicComment,
  ShareLinkData,
} from "@/lib/client-lane/types";
import { axiosPublic } from "@/services/axios";

import { DecisionPage } from "./DecisionPage";

const body = () => within(document.body);

const PIN_ON_HERO = pinComment(
  "p1",
  "craft:g1:board.g1",
  "2026-09-30T08:00:00.000Z",
  { body: "Logo smaller" }
);
const PIN_ON_FEED = pinComment(
  "p2",
  "resize:r2:tile.r2",
  "2026-09-30T09:00:00.000Z",
  { body: "Crop tighter" }
);

const APPROVED: ApprovalDecision = {
  id: "d1",
  actor: "Dina",
  outcome: "approved",
  note: null,
  pins: [],
  decided_at: "2026-09-30T12:00:00.000Z",
  advisory: false,
  deferred_until: null,
  item_id: null,
};

/**
 * The public api edge — spied, never vi.mock'ed (bun's mock registry is
 * process-global). `/s/session` hands back a lane code, so the client viewer
 * posts without a name gate.
 */
function stubApi(rows: PublicComment[] = []) {
  vi.spyOn(globalThis, "fetch").mockImplementation((async () =>
    new Response(JSON.stringify({ code: "abcdefghijklmnop" }), {
      status: 200,
    })) as typeof fetch);
  const get = vi.spyOn(axiosPublic, "get").mockImplementation((async (
    url: string
  ) => {
    if (url === "public/share-links/tok/comments") return { data: { data: rows } };
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
          data: pinComment("c_new", anchor?.id ?? "", "2026-09-30T12:00:00.000Z", {
            anchor,
            body: String(input.body),
          }),
        },
      };
    }
    if (url === "public/share-links/tok/decision") {
      return {
        data: {
          data: {
            decision: APPROVED,
            approval: pendingApproval({
              status: "approved",
              resolved_at: APPROVED.decided_at,
              decisions: [APPROVED],
            }),
          },
        },
      };
    }
    throw new Error(`unexpected POST ${url}`);
  }) as never);
  const capture = vi
    .spyOn(posthog, "capture")
    .mockImplementation(() => undefined as never);
  return { get, post, capture };
}

function renderPage(data: ShareLinkData) {
  return render(<DecisionPage token="tok" initialData={data} />);
}

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

async function openStory(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await body().findByRole("button", { name: "Resize" }));
  await user.click(
    body().getByRole("button", { name: "Open IG Story · 1080 × 1920" })
  );
  await body().findByText("Resize · IG Story · 1080 × 1920");
}

beforeEach(() => {
  vi.restoreAllMocks();
  window.localStorage.clear();
  window.sessionStorage.clear();
});

describe("DecisionPage — a three-item KV round", () => {
  it("titles the round with its item count and approves the set", async () => {
    stubApi();
    renderPage(kvRound());

    expect(body().getByRole("heading", { level: 1 })).toHaveTextContent(
      "Ramadan hero · v1 · 3 items"
    );
    expect(
      await body().findByRole("button", { name: "Approve all 3" })
    ).toBeInTheDocument();
  });

  it("opens on the grid, and a tapped card becomes the focused view", async () => {
    stubApi();
    const user = userEvent.setup();
    renderPage(kvRound());

    expect(
      await body().findByRole("button", { name: "Open Hero board" })
    ).toBeInTheDocument();
    await openStory(user);
    expect(body().getByText("2/3")).toBeInTheDocument();
  });

  it("posts a pin on the second item with that item's anchor", async () => {
    const { post, capture } = stubApi();
    const user = userEvent.setup();
    renderPage(kvRound());

    await openStory(user);
    tapPinLayer(50, 50);
    await body().findByRole("dialog", { name: /pin 1 · v1/ });
    await user.type(
      body().getByPlaceholderText(/Price tag covers/),
      "Nudge left"
    );
    await user.click(body().getByRole("button", { name: "Post" }));

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith(
        "public/share-links/tok/comments",
        expect.objectContaining({
          body: "Nudge left",
          anchor: { kind: "pin", id: "resize:r1:tile.r1", x: 0.25, y: 0.5 },
        }),
        expect.anything()
      )
    );
    expect(capture).toHaveBeenCalledWith(
      "client_lane.pin_placed",
      expect.objectContaining({ phase: "resize" })
    );
  });

  it("numbers pins across the round and lists them per item", async () => {
    stubApi([PIN_ON_HERO, PIN_ON_FEED]);
    const user = userEvent.setup();
    renderPage(kvRound());

    expect(
      await body().findByText("Craft · Hero board — 1 pin")
    ).toBeInTheDocument();
    const feedGroup = body().getByText("Resize · IG Feed · 1080 × 1080 — 1 pin")
      .parentElement as HTMLElement;
    expect(
      within(feedGroup).getByRole("button", { name: /Crop tighter/ })
    ).toHaveTextContent(/^2/);

    await user.click(body().getByRole("button", { name: "Resize" }));
    expect(
      body().getByRole("button", { name: "Open IG Feed · 1080 × 1080 · 1 pin" })
    ).toBeInTheDocument();
  });

  it("jumps to the item a listed pin sits on", async () => {
    stubApi([PIN_ON_HERO, PIN_ON_FEED]);
    const user = userEvent.setup();
    renderPage(kvRound());

    await user.click(await body().findByRole("button", { name: /Crop tighter/ }));

    expect(
      await body().findByText("Resize · IG Feed · 1080 × 1080")
    ).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Pin 2: Crop tighter" })
    ).toHaveAttribute("aria-pressed", "true");
  });

  it("numbers a new pin after every pin in the round", async () => {
    stubApi([PIN_ON_HERO, PIN_ON_FEED]);
    const user = userEvent.setup();
    renderPage(kvRound());

    await body().findByText("Craft · Hero board — 1 pin");
    await openStory(user);
    tapPinLayer(50, 50);

    expect(
      await body().findByRole("dialog", { name: /pin 3 · v1/ })
    ).toBeInTheDocument();
    expect(
      document.querySelector("[data-client-lane-pin-layer] span[aria-hidden]")
        ?.textContent
    ).toBe("3");
  });

  it("keeps ←/→ inside the pin note instead of changing item", async () => {
    stubApi();
    const user = userEvent.setup();
    renderPage(kvRound());

    await openStory(user);
    tapPinLayer(50, 50);
    await body().findByRole("dialog", { name: /pin 1 · v1/ });
    await user.click(body().getByPlaceholderText(/Price tag covers/));
    await user.keyboard("{ArrowRight}");
    expect(
      body().getByText("Resize · IG Story · 1080 × 1920")
    ).toBeInTheDocument();

    // Focus off the textarea but the sheet still open: still no stepping.
    (document.activeElement as HTMLElement | null)?.blur();
    await user.keyboard("{ArrowRight}");
    expect(
      body().getByText("Resize · IG Story · 1080 × 1920")
    ).toBeInTheDocument();
  });

  it("approves the whole round with one round-level decision", async () => {
    const { post, capture } = stubApi();
    const user = userEvent.setup();
    renderPage(kvRound());

    await user.click(await body().findByRole("button", { name: "Approve all 3" }));

    await waitFor(() =>
      expect(
        post.mock.calls.some((c) => c[0] === "public/share-links/tok/decision")
      ).toBe(true)
    );
    const call = post.mock.calls.find(
      (c) => c[0] === "public/share-links/tok/decision"
    ) as unknown[];
    const input = call[1] as Record<string, unknown>;
    expect(input).toMatchObject({ outcome: "approved" });
    expect(input).not.toHaveProperty("item_id");
    expect(input.pins).toBeUndefined();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.decision_submitted",
      expect.objectContaining({ item_count: 3 })
    );
  });

  it("closes the round against every item", async () => {
    stubApi();
    renderPage(
      kvRound({
        approval: pendingApproval({
          status: "approved",
          resolved_at: APPROVED.decided_at,
          decisions: [APPROVED],
        }),
        access: {
          role: "comment",
          expires_at: null,
          can_decide: false,
          verification_required: false,
        },
      })
    );

    expect(
      await body().findByText(/Approved by Dina on v1 · 3 items/)
    ).toBeInTheDocument();
  });
});

describe("DecisionPage — every shape C-1 can send", () => {
  it("opens a one-item round straight in the focused view", async () => {
    stubApi();
    renderPage(kvRound({ items: [approvalItem(HERO, "craft")] }));

    expect(await body().findByText("Craft · Hero board")).toBeInTheDocument();
    expect(body().getByRole("heading", { level: 1 }).textContent).toBe(
      "Ramadan hero · v1"
    );
    expect(body().getByRole("button", { name: "Approve v1" })).toBeInTheDocument();
    expect(body().queryByRole("button", { name: /All \d+ items/ })).toBeNull();
  });

  it("renders a view link as the plain gallery", async () => {
    stubApi();
    renderPage(
      kvRound({
        items: [],
        approval: null,
        version: { type: "live", id: null, label: "Latest", created_at: null },
        access: {
          role: "view",
          expires_at: null,
          can_decide: false,
          verification_required: false,
        },
      })
    );

    expect(
      await body().findByRole("button", { name: "Open Hero board full size" })
    ).toBeInTheDocument();
    expect(body().queryByRole("button", { name: /^Approve/ })).toBeNull();
  });

  it("resolves a backfilled round's artwork from the live payload", async () => {
    stubApi();
    renderPage(
      kvRound({
        items: [approvalItem(HERO, "craft", { snapshot: null, label: "v1" })],
      })
    );

    expect(await body().findByText("Craft · Hero board")).toBeInTheDocument();
    expect(body().getByRole("button", { name: "Approve v1" })).toBeInTheDocument();
  });

  it("falls back to the plain gallery when a backfilled item is gone", async () => {
    stubApi();
    renderPage(
      kvRound({
        items: [
          approvalItem(HERO, "craft", { version_id: "gone", snapshot: null }),
        ],
      })
    );

    expect(
      await body().findByRole("button", { name: "Open Hero board full size" })
    ).toBeInTheDocument();
    expect(body().getByRole("button", { name: "Approve v1" })).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.test.tsx
```

Expected: most tests fail (no item count in the heading, "Approve v1" instead of "Approve all 3", the P0a hero shows only `version.id`'s item, no grid).

- [ ] **Step 3: `KvHero` becomes a dispatcher**

Replace `src/components/client-lane/hero/KvHero.tsx` with:

```tsx
"use client";

import type { PublicKvResponse } from "@/services/query";

import { KvLinkGallery } from "../kv/KvLinkGallery";
import { KvRoundHero, type KvRoundHeroProps } from "../kv/KvRoundHero";

/**
 * The KV hero (FR-32, FR-37; multi-item rounds, spec §6.2). A round renders
 * its frozen items — stage tabs + grid, tap for the focused view with pins on
 * any item. A `view` link, or a backfilled round whose one live item is gone,
 * renders the plain gallery the old share page drew.
 */
export function KvHero({
  document,
  ...round
}: KvRoundHeroProps & { document: PublicKvResponse }) {
  if (round.items.length === 0) return <KvLinkGallery document={document} />;
  return <KvRoundHero {...round} />;
}
```

- [ ] **Step 4: `PinList` groups**

Replace `src/components/client-lane/PinList.tsx` with:

```tsx
"use client";

import { shortWhen } from "@/lib/client-lane/format";
import type { PagePin } from "@/lib/client-lane/pins";

import type { PinGroup } from "./kv/roundItems";
import { EYEBROW } from "./ui";

/**
 * The pins under the hero (FR-37): numbered per round in creation order,
 * with the note, who left it and any replies from the team. Tapping a row
 * highlights its marker (and brings up its slide or item). A multi-item
 * round passes `groups` — one section per item ("Resize · IG Story — 2 pins").
 */
export function PinList({
  pins,
  versionLabel,
  activeId,
  partLabel,
  groups,
  onSelect,
}: {
  pins: PagePin[];
  versionLabel: string;
  activeId: string | null;
  /** "Slide 2", "Story 9:16" — where the pin sits, when the hero has parts. */
  partLabel?: (pin: PagePin) => string | null;
  /** Per-item sections; flat list when absent. */
  groups?: PinGroup[];
  onSelect: (id: string) => void;
}) {
  if (pins.length === 0) return null;

  const row = (pin: PagePin, showWhere: boolean) => {
    const where = showWhere ? (partLabel?.(pin) ?? null) : null;
    const active = activeId === pin.id;
    return (
      <li key={pin.id}>
        <button
          type="button"
          onClick={() => onSelect(pin.id)}
          aria-pressed={active}
          className={[
            "flex w-full items-start gap-3 rounded-xl px-3 py-2.5 text-left transition-colors",
            active
              ? "bg-white/[0.1]"
              : "bg-white/[0.04] hover:bg-white/[0.07]",
          ].join(" ")}
        >
          <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-[#F5B800] text-[11px] font-semibold text-black">
            {pin.number}
          </span>
          <span className="flex min-w-0 flex-1 flex-col gap-0.5">
            <span className="flex items-baseline justify-between gap-2 text-[12px] text-white/50">
              <span className="truncate">
                {pin.author}
                {where ? ` · ${where}` : ""}
              </span>
              <span className="shrink-0">{shortWhen(pin.createdAt)}</span>
            </span>
            <span className="whitespace-pre-wrap text-[14px] text-white">
              {pin.body}
            </span>
            {pin.replies.map((reply) => (
              <span
                key={reply.id}
                className="mt-1 border-l border-white/15 pl-2 text-[13px] text-white/65"
              >
                <span className="text-white/45">
                  {reply.author?.name ?? "Team"}:{" "}
                </span>
                {reply.body}
              </span>
            ))}
          </span>
        </button>
      </li>
    );
  };

  return (
    <section className="flex flex-col gap-2 font-geist">
      <h2 className={EYEBROW}>
        Pins on {versionLabel} · {pins.length}
      </h2>
      {groups && groups.length > 0 ? (
        groups.map((group) => (
          <div key={group.key} className="flex flex-col gap-1.5">
            <h3 className="pt-1 text-[12px] font-medium text-white/60">
              {group.label} — {group.pins.length}{" "}
              {group.pins.length === 1 ? "pin" : "pins"}
            </h3>
            <ol className="flex flex-col gap-1.5">
              {group.pins.map((pin) => row(pin, false))}
            </ol>
          </div>
        ))
      ) : (
        <ol className="flex flex-col gap-1.5">
          {pins.map((pin) => row(pin, true))}
        </ol>
      )}
    </section>
  );
}
```

If the grouped heading renders as `Craft · Hero board — 1 pin` with extra spaces (JSX `{" "}` joins), print `h3.textContent` once and keep the expectation matching the spec copy "{label} — {n} pin(s)".

- [ ] **Step 5: `DecisionBar` label**

In `DecisionBar.tsx`, the props (lines 12-26) replace `versionLabel` with `approveLabel`:

```tsx
export function DecisionBar({
  approval,
  approveLabel,
  busy,
  onApprove,
  onRequestChanges,
  onMoreTime,
}: {
  approval: Approval;
  /** "Approve v3" for one item, "Approve all 4" for a set (round.ts). */
  approveLabel: string;
  busy: boolean;
  onApprove: () => void;
  onRequestChanges: () => void;
  onMoreTime: () => void;
}) {
```

Line 42 becomes `{approveLabel}`.

- [ ] **Step 6: Analytics props**

In `client-lane-events.ts`, add `ApprovalItemPhase` to the existing type import (keep the separate `KvSharePhase` import Task 2 added):

```ts
import type {
  ApprovalItemPhase,
  ApprovalPolicy,
  DecisionOutcome,
  ShareSubjectType,
} from "@/lib/client-lane/types";
import type { KvSharePhase } from "@/types/kv/share-link";
```

`trackClientDecisionSubmitted` (lines 127-136) gains after `resumed: boolean;`:

```ts
  /** Items the decision covers — the whole round in Phase 1. */
  item_count: number;
```

`trackClientPinPlaced` (lines 153-156) becomes:

```ts
export const trackClientPinPlaced = (props: {
  subject_type: ShareSubjectType;
  verified: boolean;
  /** The item's phase (`deck` for a deck slide). */
  phase: ApprovalItemPhase;
}) => safeCapture("client_lane.pin_placed", props);
```

- [ ] **Step 7: DecisionPage**

Apply in order (line numbers are pre-edit HEAD + the Task 3 bridge):

Line 25 (`import { findKvTarget } …`) becomes:

```tsx
import {
  approvalItemsOf,
  approveLabel,
  roundItemCount,
  roundVersionIds,
  withItemCount,
} from "@/lib/client-lane/round";
```

Lines 36-40 (the `import type { GuestIdentity, PublicComment, ShareLinkData }` block) become:

```tsx
import type {
  GuestIdentity,
  PublicComment,
  ShareLinkData,
} from "@/lib/client-lane/types";
import type { KvSharePhase } from "@/types/kv/share-link";
```

Line 53 (`import { itemLabel } from "./kv/kvItems";`) becomes:

```tsx
import {
  itemForPin,
  kvRoundItems,
  pinGroups,
  type KvRoundItem,
} from "./kv/roundItems";
```

`PinDraftState` (lines 90-94) becomes:

```tsx
/** An unsaved pin: where it goes and which item (version) it sits on. */
interface PinDraftState {
  stage: PinStage;
  version: string;
  part: string;
  x: number;
  y: number;
}
```

After line 126 (`const [pinDraft, setPinDraft] = …`) add:

```tsx
  /** KV round: the item in the focused view; `null` = the grid (spec §6.2). */
  const [focusedItemId, setFocusedItemId] = useState<string | null>(null);
```

Line 147 (`const versionId = data.version.id;`) becomes:

```tsx
  const itemCount = roundItemCount(data);
  /**
   * Deck: the round's one item (C-1 `items[0]`), falling back to `version.id`
   * for an api that predates items. KV rounds pin per item instead.
   */
  const versionId = approvalItemsOf(data)[0]?.version_id ?? data.version.id;
```

Lines 172-176 (`kvTarget` memo) become:

```tsx
  const roundItems = useMemo<KvRoundItem[]>(
    () => (data.type === "kv_file" ? kvRoundItems(data) : []),
    [data]
  );
```

The Task 3 bridge (the `pins` memo) becomes:

```tsx
  const pins = useMemo<PagePin[]>(
    () => pinsFromComments(comments, roundVersionIds(data)),
    [comments, data]
  );
```

In `trackClientDecisionSubmitted({...})` (lines 304-312) add after `resumed,`:

```tsx
            item_count: itemCount,
```

and the `doSubmit` deps (line 367) become `[token, laneCode, data.type, data.viewer.email, refresh, itemCount]`.

Replace lines 413-531 (from `/* ── Pins ── */` through the `draftOnCurrentPart` declaration) with:

```tsx
  /* ── Pins ──────────────────────────────────────────────────────────── */

  const pinnable =
    commentsEnabled &&
    !busy &&
    (data.type === "deck"
      ? versionId !== null
      : data.type === "kv_file" && roundItems.length > 0);

  const placePin = (
    target: Pick<PinDraftState, "stage" | "version" | "part">,
    x: number,
    y: number
  ) => {
    setPinDraft({ ...target, x, y });
    setSheet({ kind: "pinNote" });
  };

  const cancelPin = () => {
    setPinDraft(null);
    setSheet(null);
  };

  // Same split as `doSubmit`/`submitDecision` above, and for the same
  // reason: a `guest_required` retry must carry the identity the name gate
  // just returned, not re-derive it from a `withIdentity` call that would
  // still see the rejected lane.
  const doPostPin = useCallback(
    (draft: PinDraftState, body: string, g: GuestIdentity | null) => {
      void (async () => {
        setBusy(true);
        setError(null);
        try {
          const created = await postPublicComment(
            token,
            {
              body,
              anchor: buildPinAnchor(
                { stage: draft.stage, version: draft.version, part: draft.part },
                draft.x,
                draft.y
              ) as { kind: "pin"; id: string; x: number; y: number },
              ...(g ? { guest_name: g.name, guest_email: g.email } : {}),
            },
            laneCode
          );
          trackClientPinPlaced({
            subject_type: data.type,
            verified: g === null,
            phase:
              data.type === "deck" ? "deck" : (draft.stage as KvSharePhase),
          });
          setComments((prev) => [...prev, created]);
          setSessionPins((prev) => [...prev, created.id]);
          setActivePinId(created.id);
          setPinDraft(null);
          setSheet(null);
        } catch (e) {
          const err = publicApiError(e);
          trackClientPinFailed({
            subject_type: data.type,
            verified: g === null,
            reason: failureReason(err),
            http_status: err.status,
          });
          if (err.code === "guest_required") {
            setLaneRejected(true);
            clearGuest();
            setGuest(null);
            afterIdentityRef.current = (identity) =>
              doPostPin(draft, body, identity);
            setSheet({ kind: "name" });
          } else {
            setError(err.message ?? "Couldn't save the pin. Try again.");
          }
        } finally {
          setBusy(false);
        }
      })();
    },
    [token, laneCode, data.type]
  );

  const postPin = (body: string) => {
    const draft = pinDraft;
    if (!draft) return;
    withIdentity((g) => doPostPin(draft, body, g));
  };

  const selectPin = (id: string | null) => {
    setActivePinId(id);
    if (!id) return;
    const pin = pins.find((p) => p.id === id);
    if (!pin) return;
    if (data.type === "kv_file") {
      // A listed pin on another item brings that item into view (spec §6.2).
      const entry = itemForPin(roundItems, pin);
      if (entry) setFocusedItemId(entry.id);
      return;
    }
    if (data.type !== "deck") return;
    const index = data.document.slides.findIndex(
      (s) => slidePart(s.id) === pin.part
    );
    if (index >= 0) setSlideIndex(index);
  };

  const pinPartLabel = (pin: PagePin): string | null => {
    if (data.type === "deck") {
      const index = data.document.slides.findIndex(
        (s) => slidePart(s.id) === pin.part
      );
      return index >= 0 ? `Slide ${index + 1}` : null;
    }
    if (data.type === "kv_file") {
      return itemForPin(roundItems, pin)?.caption ?? null;
    }
    return null;
  };

  /* ── Render ────────────────────────────────────────────────────────── */

  const deckDraft =
    pinDraft &&
    data.type === "deck" &&
    data.document.slides[slideIndex] &&
    pinDraft.part === slidePart(data.document.slides[slideIndex].id)
      ? { x: pinDraft.x, y: pinDraft.y }
      : null;
```

In the `hero` expression (lines 533-567): the DeckHero `draft={draftOnCurrentPart}` becomes `draft={deckDraft}` and its `onPlacePin` becomes:

```tsx
        onPlacePin={
          pinnable && versionId !== null
            ? (part, x, y) =>
                placePin({ stage: DECK_STAGE, version: versionId, part }, x, y)
            : undefined
        }
```

and the `<KvHero … />` element (lines 552-560) becomes:

```tsx
      <KvHero
        document={data.document}
        items={roundItems}
        pins={pins}
        draft={
          pinDraft
            ? { version: pinDraft.version, x: pinDraft.x, y: pinDraft.y }
            : null
        }
        activePinId={activePinId}
        focusedId={focusedItemId}
        onFocusChange={(id) => {
          setFocusedItemId(id);
          setActivePinId(null);
        }}
        keyboardEnabled={sheet === null}
        onPlacePin={
          pinnable
            ? (entry, x, y) =>
                placePin(
                  { stage: entry.phase, version: entry.versionId, part: entry.part },
                  x,
                  y
                )
            : undefined
        }
        onSelectPin={selectPin}
      />
```

Header version (lines 624-627) becomes:

```tsx
              <span className="font-normal text-white/50">
                {" · "}
                {withItemCount(data.version.label, itemCount)}
              </span>
```

`<PinList …>` (lines 638-644) gains, after `partLabel={pinPartLabel}`:

```tsx
              groups={
                data.type === "kv_file" && roundItems.length > 1
                  ? pinGroups(roundItems, pins)
                  : undefined
              }
```

`<TerminalBanner … versionLabel={data.version.label} />` (line 683) becomes `versionLabel={withItemCount(data.version.label, itemCount)}`.

`<DecisionBar …>` (lines 688-697): replace `versionLabel={data.version.label}` with `approveLabel={approveLabel(data.version.label, itemCount)}`.

Delete the now-unused `PinStage`-typed `pinStage` references (gone with the replaced block) and confirm `PinStage` is still imported for `PinDraftState`.

- [ ] **Step 8: Delete `kvTarget.ts`**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git rm src/lib/client-lane/kvTarget.ts && rtk proxy grep -rn "kvTarget\|findKvTarget\|KvTarget" src || echo "no references left"
```

Expected: `no references left`.

- [ ] **Step 9: Run — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvRoundHero.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvLinkGallery.test.tsx
```

- [ ] **Step 10: Mutation check**

(a) `selectPin` without the KV branch → "jumps to the item…" fails; (b) `keyboardEnabled={true}` → the second half of "keeps ←/→ inside the pin note" fails; (c) `pinsFromComments(comments, new Set([versionId]))` (P0a scope) → "numbers pins across the round" fails; (d) `approveLabel` replaced by `` `Approve ${data.version.label}` `` → first and "approves the whole round" fail; (e) send `item_id: roundItems[0].id` in the approve draft → `not.toHaveProperty("item_id")` fails; (f) `groups={undefined}` → per-item headings test fails; (g) `kvRoundItems` → `[]` always → one-item/backfilled tests fail; (h) `KvHero` always renders `KvRoundHero` → view-link test crashes/fails.

- [ ] **Step 11: Format, lint, type-check, commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx prettier --write src/components/client-lane/hero/KvHero.tsx src/components/client-lane/PinList.tsx src/components/client-lane/DecisionBar.tsx src/lib/analytics/client-lane-events.ts src/components/client-lane/DecisionPage.tsx src/components/client-lane/DecisionPage.test.tsx && bunx eslint src/components/client-lane/hero/KvHero.tsx src/components/client-lane/PinList.tsx src/components/client-lane/DecisionBar.tsx src/lib/analytics/client-lane-events.ts src/components/client-lane/DecisionPage.tsx src/components/client-lane/DecisionPage.test.tsx && bunx tsc --noEmit -p . 2>&1 | grep -E "client-lane/(hero/KvHero|PinList|DecisionBar|DecisionPage)|client-lane-events" ; wc -c src/components/client-lane/DecisionPage.tsx src/components/client-lane/DecisionPage.test.tsx
```

Expected: grep prints nothing; the test file is < 45 000 bytes.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add src/components/client-lane/hero/KvHero.tsx src/components/client-lane/PinList.tsx src/components/client-lane/DecisionBar.tsx src/lib/analytics/client-lane-events.ts src/components/client-lane/DecisionPage.tsx src/components/client-lane/DecisionPage.test.tsx src/lib/client-lane/kvTarget.ts && git commit -m "$(cat <<'EOF'
feat(web): decision page renders a KV round's items with pins on any item

Header and banner read "v{round} · {n} items", "Approve all {n}",
PinList grouped per item, a listed pin focuses its item. kvTarget.ts
is replaced by the items model. decision_submitted gains item_count,
pin_placed gains phase.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: OG card + page title

**Files:**
- Modify: `src/lib/client-lane/round.ts` (append), `src/lib/client-lane/round.test.ts` (append)
- Modify: `src/app/s/[token]/page.tsx` (lines 3-11, 75-79, 101)
- Modify: `src/app/s/[token]/opengraph-image.tsx` (lines 5-8, 234-248, 320)

**Interfaces:**
- Consumes: `withItemCount`, `roundItemCount`, `ogDecisionPill`, `ogThumbnailUrl` (Task 1).
- Produces: `shareTitle(data: ShareLinkData): string`; `shareImageAlt(data: ShareLinkData): string`.

- [ ] **Step 1: Write the failing tests**

Append to `src/lib/client-lane/round.test.ts` (and add `shareImageAlt, shareTitle` to its import from `./round`):

```ts
describe("shareTitle / shareImageAlt", () => {
  it("carries the item count in the metadata title and image alt", () => {
    expect(shareTitle(kvRound())).toBe(
      "For Dina · Ramadan hero · v1 · 3 items — Garuda via Alva"
    );
    expect(shareImageAlt(kvRound())).toBe("Ramadan hero · v1 · 3 items");
  });

  it("keeps a one-item round's title as P0a had it, without the personal prefix for a guest", () => {
    const one = kvRound({
      items: [approvalItem(HERO, "craft")],
      viewer: { kind: "anonymous", name: null, email: null },
    });
    expect(shareTitle(one)).toBe("Ramadan hero · v1 — Garuda via Alva");
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/round.test.ts
```

- [ ] **Step 3: Implement**

Append to `src/lib/client-lane/round.ts`:

```ts

/**
 * `generateMetadata`'s title (C-6): "{title} · v2 · 3 items — {brand} via
 * {workspace}", prefixed "For {name} · " for a personal lane. The object
 * link's card, never a personal one, carries the same title.
 */
export function shareTitle(data: ShareLinkData): string {
  const viewerPrefix =
    data.viewer.kind === "client" && data.viewer.name
      ? `For ${data.viewer.name} · `
      : "";
  return `${viewerPrefix}${shareImageAlt(data)} — ${data.brand.name} via ${data.workspace.name}`;
}

/** The OG image's alt: "{title} · v2 · 3 items". */
export function shareImageAlt(data: ShareLinkData): string {
  return `${data.subject.title} · ${withItemCount(data.version.label, roundItemCount(data))}`;
}
```

In `src/app/s/[token]/page.tsx`, add to the imports (after line 10):

```tsx
import { shareImageAlt, shareTitle } from "@/lib/client-lane/round";
```

Replace lines 75-79 (`viewerPrefix` + `title`) with:

```tsx
  const title = shareTitle(data);
```

Line 101 (`alt: …`) becomes `alt: shareImageAlt(data),`.

In `src/app/s/[token]/opengraph-image.tsx`, add to the imports (after line 7):

```tsx
import {
  ogDecisionPill,
  ogThumbnailUrl,
  roundItemCount,
} from "@/lib/client-lane/round";
```

Line 247 (`Needs your decision`) becomes:

```tsx
              {ogDecisionPill(roundItemCount(data))}
```

Line 320 becomes:

```tsx
    data ? thumbnailDataUrl(ogThumbnailUrl(data)) : Promise.resolve(null),
```

Update the file's header doc (lines 13-15) to read: "1200×630 PNG, ≤ 250 KB: the round's first item's frozen still (falling back to the subject thumbnail), the type, the title, the version label, the brand, "via {workspace}", and "Needs your decision" — prefixed "{n} items · " for a multi-item round — while the round is open."

- [ ] **Step 4: Run — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/round.test.ts
```

- [ ] **Step 5: Mutation check**

(a) `shareImageAlt` without `withItemCount` → first test fails; (b) drop the `data.viewer.kind === "client"` guard → second test fails.

- [ ] **Step 6: Smoke the OG route locally (optional, needs the api branch on :9191)**

With the multi-item api running and a real round token: `curl -s -o /tmp/og.png -w "%{http_code} %{size_download}\n" http://localhost:3001/s/<token>/opengraph-image` → `200` and ≤ 256000 bytes; open the PNG and see the first item and "3 items · Needs your decision". Skip if the api is not available and note it in the track file.

- [ ] **Step 7: Format, lint, type-check, commit**

The `[token]` paths MUST stay double-quoted — zsh treats unquoted `[…]` as a glob and aborts with "no matches found".

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx prettier --write src/lib/client-lane/round.ts src/lib/client-lane/round.test.ts "src/app/s/[token]/page.tsx" "src/app/s/[token]/opengraph-image.tsx" && bunx eslint src/lib/client-lane/round.ts src/lib/client-lane/round.test.ts "src/app/s/[token]/page.tsx" "src/app/s/[token]/opengraph-image.tsx" && bunx tsc --noEmit -p . 2>&1 | grep -E "client-lane/round|app/s/"
```

Expected: the grep prints nothing.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add src/lib/client-lane/round.ts src/lib/client-lane/round.test.ts "src/app/s/[token]/page.tsx" "src/app/s/[token]/opengraph-image.tsx" && git commit -m "$(cat <<'EOF'
feat(web): share title and OG card name a multi-item round's item count

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Status block + editor pin labels

**Files:**
- Modify: `src/components/client-lane/agency/ApprovalStatusBlock.tsx` (lines 65-76, 108-119)
- Create: `src/components/client-lane/agency/ApprovalStatusBlock.test.tsx`
- Create: `src/lib/client-lane/versionLabels.ts`, `src/lib/client-lane/versionLabels.test.ts`
- Modify: `src/services/client-lane.ts` (line 6 import; append hook)
- Modify: `src/lib/studio/kv/kvCommentAdapter.ts` (lines 139-153, 173-176)
- Modify: `src/lib/studio/kv/kvCommentAdapter.test.ts` (append)
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (after line 220; after line 3279; lines 8830-8834)

**Interfaces:**
- Consumes: `AgencyApproval.items`, `AgencyApprovalItem.version_id?` (Task 1, D-1).
- Produces:
  - `approvalVersionLabels(approvals: Pick<AgencyApproval, "round" | "items" | "rounds">[]): Map<string, string>`
  - `useApprovalVersionLabels(subjectType: ShareSubjectType, subjectId: string | null | undefined, opts?: { enabled?: boolean }): ReadonlyMap<string, string>`
  - `kvAnchorLabel` ctx gains `versionLabelById?: ReadonlyMap<string, string>`

- [ ] **Step 1: Write the failing tests**

Create `src/lib/client-lane/versionLabels.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { approvalVersionLabels } from "./versionLabels";

const item = (id: string, version_id?: string) => ({
  id,
  phase: "resize" as const,
  label: id,
  status: "pending" as const,
  thumbnail_url: null,
  ...(version_id ? { version_id } : {}),
});

describe("approvalVersionLabels", () => {
  it("labels every item's version with its round, the newest round winning", () => {
    const map = approvalVersionLabels([
      { round: 2, items: [item("a", "g1"), item("b", "r1")], rounds: [] },
      { round: 1, items: [item("c", "g1")], rounds: [] },
    ]);
    expect(map.get("g1")).toBe("v2");
    expect(map.get("r1")).toBe("v2");
  });

  it("falls back to earlier rounds' version ids when items carry none (D-1 not shipped)", () => {
    const map = approvalVersionLabels([
      {
        round: 2,
        items: [item("a")],
        rounds: [
          {
            round: 1,
            status: "changes_required",
            version: { type: "kv_resize_export", id: "r9", label: "v1", created_at: null },
            resolved_at: null,
          },
        ],
      },
    ]);
    expect(map.get("r9")).toBe("v1");
    expect(map.size).toBe(1);
  });
});
```

Create `src/components/client-lane/agency/ApprovalStatusBlock.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, within } from "@testing-library/react";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import axiosInstance from "@/services/axios";

import { ApprovalStatusBlock } from "./ApprovalStatusBlock";

const body = () => within(document.body);

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function round(overrides: Record<string, unknown> = {}) {
  return {
    id: "ap2",
    round: 2,
    policy: "optional",
    status: "changes_required",
    message: null,
    sent_at: null,
    deferred_until: null,
    deferred_note: null,
    resolved_at: "2026-09-30T12:00:00.000Z",
    approvers: [],
    decisions: [
      {
        id: "d1",
        actor: "Dina",
        outcome: "changes_required",
        note: null,
        pins: ["c1", "c2"],
        decided_at: null,
        advisory: false,
        deferred_until: null,
        item_id: null,
      },
    ],
    rounds: [],
    subject_type: "kv_file",
    subject_id: "f1",
    share_link_id: "l1",
    items: ["a", "b", "c"].map((id) => ({
      id,
      phase: "resize",
      label: id,
      status: "changes_required",
      thumbnail_url: null,
    })),
    ...overrides,
  };
}

/** `GET v1/approvals` spied, never vi.mock'ed. */
function stubApprovals(rows: unknown[]) {
  vi.spyOn(axiosInstance, "get").mockImplementation((async (url: string) => {
    if (url === "v1/approvals") return { data: { data: rows, share_url: null } };
    throw new Error(`unexpected GET ${url}`);
  }) as never);
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("ApprovalStatusBlock", () => {
  it("names a multi-item round's item count in its header", async () => {
    stubApprovals([round()]);
    render(<ApprovalStatusBlock subjectType="kv_file" subjectId="f1" />, {
      wrapper: Wrapper,
    });

    expect(
      await body().findByText("Approval · round 2 · 3 items")
    ).toBeInTheDocument();
  });

  it("keeps a one-item round's header as it was", async () => {
    stubApprovals([round({ items: [round().items[0]] })]);
    render(<ApprovalStatusBlock subjectType="kv_file" subjectId="f1" />, {
      wrapper: Wrapper,
    });

    expect(await body().findByText("Approval · round 2")).toBeInTheDocument();
  });

  it("shows how many pins came with each decision", async () => {
    stubApprovals([round()]);
    render(<ApprovalStatusBlock subjectType="kv_file" subjectId="f1" />, {
      wrapper: Wrapper,
    });

    const row = (await body().findByText("Dina")).closest("li") as HTMLElement;
    expect(row).toHaveTextContent("Dina · Changes requested · 2 pins");
  });
});
```

Append to `src/lib/studio/kv/kvCommentAdapter.test.ts`:

```ts
describe("kvAnchorLabel — approval-round versions", () => {
  // A client's pin through the share link: its version is the frozen resize
  // ROW id, which is never one of the file's generations.
  const clientPin = buildPinAnchor(
    { stage: "resize", version: "rowexport1", part: tilePart("rowexport1") },
    0.5,
    0.5
  );

  it("reads a pin on a frozen approval item as 'on v{round}'", () => {
    const label = kvAnchorLabel(clientPin, {
      generations,
      versionLabelById: new Map([["rowexport1", "v2"]]),
    });

    expect(label).toContain("on v2");
    expect(label).not.toContain("older version");
  });

  it("still says 'older version' when neither a generation nor a round knows it", () => {
    const label = kvAnchorLabel(clientPin, {
      generations,
      versionLabelById: new Map(),
    });

    expect(label).toContain("older version");
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/versionLabels.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/ApprovalStatusBlock.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/studio/kv/kvCommentAdapter.test.ts
```

Expected: module not found; header reads "Approval · round 2"; no pin count; adapter says "older version".

- [ ] **Step 3: `versionLabels.ts`**

Create `src/lib/client-lane/versionLabels.ts`:

```ts
import type { AgencyApproval } from "@/services/client-lane";

/**
 * version id → "v{round}" for every item any round froze (spec §6.3), so an
 * editor pin a client left through the share link reads "on v2" instead of
 * "older version" — its version is a frozen item id (a resize row, a motion
 * export), never one of the file's generations.
 *
 * Rounds arrive newest first (C-9). A version frozen into several rounds (an
 * unchanged board re-sent) keeps its NEWEST round: that is the one in play.
 * Items only carry `version_id` once contract deviation D-1 ships; until then
 * each round's `rounds[].version.id` (its first item) still labels.
 */
export function approvalVersionLabels(
  approvals: Pick<AgencyApproval, "round" | "items" | "rounds">[]
): Map<string, string> {
  const out = new Map<string, string>();
  const label = (id: string | null | undefined, round: number) => {
    if (id && !out.has(id)) out.set(id, `v${round}`);
  };
  for (const approval of approvals) {
    for (const item of approval.items ?? []) label(item.version_id, approval.round);
  }
  for (const approval of approvals) {
    for (const earlier of approval.rounds) label(earlier.version.id, earlier.round);
  }
  return out;
}
```

- [ ] **Step 4: The hook**

In `src/services/client-lane.ts` line 6 becomes:

```ts
import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
```

and add `import { approvalVersionLabels } from "@/lib/client-lane/versionLabels";` below the `axiosInstance` import. Append:

```ts

/**
 * `versionLabelById` for a subject's comment panel: every frozen round item's
 * version → "v{round}" (spec §6.3). Empty until the rounds load, and when the
 * query is disabled (flag off).
 */
export function useApprovalVersionLabels(
  subjectType: ShareSubjectType,
  subjectId: string | null | undefined,
  opts: { enabled?: boolean } = {}
): ReadonlyMap<string, string> {
  const approvals = useApprovals(subjectType, subjectId, opts);
  return useMemo(
    () => approvalVersionLabels(approvals.data?.data ?? []),
    [approvals.data]
  );
}
```

- [ ] **Step 5: `kvAnchorLabel`**

In `kvCommentAdapter.ts`, the `ctx` type (lines 141-152) gains after `tilePlatforms?: Record<string, string>;`:

```ts
    /**
     * Client-lane round labels: a frozen approval item's version → "v2"
     * (`useApprovalVersionLabels`). Only consulted when no generation owns
     * the version, so canvas pins keep their generation label.
     */
    versionLabelById?: ReadonlyMap<string, string>;
```

Lines 173-176 become:

```ts
  const generation = ctx.generations.find((g) => g.id === version);
  const roundLabel = ctx.versionLabelById?.get(version);
  // A version number the file no longer has means the render was purged —
  // unless a client pinned it through an approval round, which names it.
  // Say so rather than printing a raw ULID at the reader.
  segments.push(
    generation
      ? `v${generation.version_number}`
      : roundLabel
        ? `on ${roundLabel}`
        : "older version"
  );
```

- [ ] **Step 6: Wire the editor**

In `KvGeneratorLayout.tsx`, after line 220 (end of the `kvCommentAdapter` import) add:

```tsx
import { useApprovalVersionLabels } from "@/services/client-lane";
```

After line 3279 (end of the `tilePlatforms` `useMemo`) add:

```tsx
  // Client lane: pins a client left through an approval link sit on frozen
  // item versions (resize rows, motion exports) the stream doesn't know —
  // label them "on v{round}" rather than "older version" (spec §6.3).
  // Inlined flag read (same as useClientLaneEnabled) so this file adds no new
  // named import from the widely-mocked `@/lib/featureFlags`.
  const clientLaneOn =
    useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.CLIENT_LANE) === true;
  const approvalVersionLabelById = useApprovalVersionLabels(
    "kv_file",
    liveFileId,
    { enabled: clientLaneOn }
  );
```

Lines 8830-8834 become:

```tsx
                kvAnchorLabel(thread.parent.anchor, {
                  tilePlatforms,
                  generations: stream.generations,
                  boardOrder,
                  versionLabelById: approvalVersionLabelById,
                })
```

Before editing, confirm no early `return` sits between the component start and line 3279 (hooks must stay unconditional): `sed -n 600,3280p src/components/studio/kv-generator/KvGeneratorLayout.tsx | rtk proxy grep -nE "^  return[ ;(]"` must print nothing, and that `clientLaneOn` is not already declared in the file (`rtk proxy grep -n "clientLaneOn" src/components/studio/kv-generator/KvGeneratorLayout.tsx` prints only your new lines).

- [ ] **Step 7: `ApprovalStatusBlock`**

Line 75 (`Approval · round {current.round}`) becomes:

```tsx
          Approval · round {current.round}
          {(current.items?.length ?? 0) > 1
            ? ` · ${current.items?.length} items`
            : ""}
```

In the decision row (lines 108-119), after `{d.advisory ? " · advisory" : ""}` add:

```tsx
              {d.pins.length > 0
                ? ` · ${d.pins.length} ${d.pins.length === 1 ? "pin" : "pins"}`
                : ""}
```

- [ ] **Step 8: Run — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/versionLabels.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/ApprovalStatusBlock.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/studio/kv/kvCommentAdapter.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvGeneratorLayout.measureImageUrl.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

(The last two prove the layout still imports cleanly and the status block inside the share panel still renders.)

- [ ] **Step 9: Mutation check**

(a) iterate approvals oldest-first → "newest round winning" fails; (b) drop the `rounds[]` loop → D-1 fallback test fails; (c) header suffix on `> 0` → one-item test fails; (d) drop the pin-count span → decision test fails; (e) `kvAnchorLabel` ignores `versionLabelById` → "on v{round}" test fails.

- [ ] **Step 10: Format, lint, type-check, commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx prettier --write src/components/client-lane/agency/ApprovalStatusBlock.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/lib/client-lane/versionLabels.ts src/lib/client-lane/versionLabels.test.ts src/services/client-lane.ts src/lib/studio/kv/kvCommentAdapter.ts src/lib/studio/kv/kvCommentAdapter.test.ts src/components/studio/kv-generator/KvGeneratorLayout.tsx && bunx eslint src/components/client-lane/agency/ApprovalStatusBlock.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/lib/client-lane/versionLabels.ts src/lib/client-lane/versionLabels.test.ts src/services/client-lane.ts src/lib/studio/kv/kvCommentAdapter.ts src/lib/studio/kv/kvCommentAdapter.test.ts src/components/studio/kv-generator/KvGeneratorLayout.tsx && bunx tsc --noEmit -p . 2>&1 | grep -E "ApprovalStatusBlock|versionLabels|services/client-lane|kvCommentAdapter" ; bunx tsc --noEmit -p . 2>&1 | grep -c "KvGeneratorLayout.tsx"
```

(The 414 KB layout may carry pre-existing eslint findings. Before Step 6, run `bunx eslint src/components/studio/kv-generator/KvGeneratorLayout.tsx > /private/tmp/layout-eslint-before.txt 2>&1`; after it, run the same into `…-after.txt` and `diff` them — new findings must be zero. Never `git stash` to get a baseline.)

Expected: first grep prints nothing; the `KvGeneratorLayout.tsx` count is ≤ the Task 0 baseline.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add src/components/client-lane/agency/ApprovalStatusBlock.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/lib/client-lane/versionLabels.ts src/lib/client-lane/versionLabels.test.ts src/services/client-lane.ts src/lib/studio/kv/kvCommentAdapter.ts src/lib/studio/kv/kvCommentAdapter.test.ts src/components/studio/kv-generator/KvGeneratorLayout.tsx && git commit -m "$(cat <<'EOF'
feat(web): approval status names the item count; editor labels client pins by round

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Gates, manual smoke, tri-mode check, track file

**Files:**
- Modify: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:** none.

- [ ] **Step 1: Type gate on every touched file**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bunx tsc --noEmit -p . 2>&1 | grep -E "src/(lib/client-lane|components/client-lane|services/client-lane|lib/analytics/client-lane-events|components/studio/kv-generator/KvSharePanel|lib/studio/kv/kvCommentAdapter|app/s/)"; echo "grep-exit=$?"; bunx tsc --noEmit -p . 2>&1 | grep -c "error TS"; bunx tsc --noEmit -p . 2>&1 | grep -c "KvGeneratorLayout.tsx"
```

Expected: `grep-exit=1` (no matches); total count ≤ Task 0 baseline; layout count ≤ its baseline.

- [ ] **Step 2: Lint every touched file**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git diff --name-only --diff-filter=d develop...HEAD -- 'src/*.ts' 'src/*.tsx' | xargs bunx eslint
```

- [ ] **Step 3: Run every touched suite, one per invocation**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && for f in src/lib/client-lane/round.test.ts src/services/client-lane.test.ts src/components/studio/kv-generator/KvSharePanel.test.tsx src/components/brands/campaign-planner/SharePlanDialog.test.tsx src/lib/client-lane/pins.test.ts src/components/client-lane/kv/roundItems.test.ts src/components/client-lane/kv/KvShareBoardCanvas.test.tsx src/components/client-lane/PinLayer.test.tsx src/components/client-lane/kv/swipe.test.ts src/components/client-lane/kv/KvLinkGallery.test.tsx src/components/client-lane/kv/KvRoundHero.test.tsx src/components/client-lane/DecisionPage.test.tsx src/lib/client-lane/versionLabels.test.ts src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/lib/studio/kv/kvCommentAdapter.test.ts src/components/studio/kv-generator/KvGeneratorLayout.measureImageUrl.test.ts; do echo "== $f"; bun test "$f" 2>&1 | tail -4; done
```

Expected: every block reports `0 fail`. Also confirm size limits: `wc -c` on each new/changed `*.test.tsx` < 45 000.

- [ ] **Step 4: Manual smoke (needs the api branch)**

Start the multi-item api (`feature/daffa/vc-client-lane-multi-item` in `api/`, migrated with `TELESCOPE_ENABLED=false`, on `:9191`) — confirm its cwd with `lsof -a -p $(lsof -ti :9191 | head -1) -d cwd`. Start this worktree's web on a second port so Daffa's `:3000` is untouched: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun dev -p 3001`. Then:

1. KV file with 1 Craft board + 3 Resize tiles marked ready. Share → New link → toggle Request approval → the stage pills stay with counts; pick Craft + Resize; Send → send step shows the link.
2. Status block reads "Approval · round 1 · 4 items".
3. Open the link on a laptop: header "… · v1 · 4 items"; tabs Craft/Resize; tap a tile → focused view; ←/→ steps; pin on a resize tile; pin number continues across items; PinList grouped per item; "Approve all 4".
4. Same link on a phone (or DevTools 375×812): grid → focused view fills the screen width, swipe steps, the note sheet opens over it, decision bar reachable.
5. Edit and unmark the Craft board in the editor → reload the client page → the board is unchanged (frozen snapshot).
6. Back in the editor, the comment panel labels the client's resize pin "Resize · on v1 · …".
7. Deck and plan share sheets: request approval still works; the deck `/s/*` page looks as before ("Approve v{n}").
8. WhatsApp/OG: `…/s/<token>/opengraph-image` shows the first item and "4 items · Needs your decision".
9. PostHog Live Events (project FRnD_OS / 389744): `client_lane.approval_requested` with `item_count`/`phases`, `client_lane.gallery_item_opened`, `client_lane.pin_placed` with `phase`, `client_lane.decision_submitted` with `item_count` — no PII on the public ones.

If the api branch is not runnable yet, record "manual e2e pending — api not deployed" in the track file; do not mark Implementation completed.

- [ ] **Step 5: Tri-mode visual check**

Switch the app theme (profile menu) through **Midnight, Aurora, Daylight** and check: the KV share sheet in approval mode (stage pills, badges, approvers, Send button), the status block (item count, pin counts, tone colours), the deck and plan request panels. Nothing unreadable, no dark slab in Daylight. Then open `/s/<token>` under each theme: it must stay dark (`data-theme-scope="dark"`) in all three.

- [ ] **Step 6: Taxonomy rows (human step)**

Ask Daffa to add/update rows in the Lark "frndOS Event Taxonomy" (https://fcn.sg.larksuite.com/wiki/DMbKwqbzQiWrXSkha5zl1wFvgod): `client_lane.approval_requested` (+`item_count` number, +`phases` string[]), `client_lane.decision_submitted` (+`item_count` number), `client_lane.pin_placed` (+`phase` sketch|craft|resize|motion|deck), new `client_lane.gallery_item_opened` (`phase`, `index` 0-based; public, PII-free; fires on grid taps only).

- [ ] **Step 7: Update the track file and commit**

In `docs/tracks/client-lane-multi-item.track.md`: tick Tasks 1-9, set Implementation to `completed` (or `in_progress` with "manual e2e pending"), record the Step 1 tsc numbers, list any manual items not done, and append a session-log entry naming what was verified and what is pending (D-1 status, e2e, taxonomy).

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && git add docs/tracks/client-lane-multi-item.track.md && git commit -m "$(cat <<'EOF'
docs(web): track multi-item approval rounds — gates and verification

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

Do not push; tell Daffa the branch is ready.
