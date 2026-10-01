# Client Lane KV Approval Requests — Web (Part A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A KV approval is a *request* of N artboards, each with its own approval: the agency sends one from a new "Approval requests" section of the Share dialog (the New-link toggle is gone), and the client decides artboard by artboard on the request's own `/s/{token}` link.

**Architecture:** Wire types for C-1/C-3 request links and the `v1/approval-requests` agency endpoints land first, with pure helpers (`lib/client-lane/requests.ts`, `statusTone.ts`). The agency side gets three v2 files — `KvRequestForm` (preview-driven form, phase chips, approvers, message, Decide by → the existing send step), `KvApprovalRequestsSection` (one `ItemRow` per request + `ActionMenu`, expandable per-artboard rows) — mounted by `KvSharePanel`, whose create form goes back to access-only. The public side adds one pure model (`kv/requestItems.ts` → `RequestArtboard[]`, progress, Approve-all plan), a `KvRequestHero` (grid with per-card state + ✓/✎, `KvFocusedItem` when focused) and a `RequestRail`; `DecisionPage` branches on `requestOf(data)` and posts `approval_ids` per decision. Deck, plan, KV view links and legacy KV round links keep today's code path untouched.

**Tech Stack:** Next.js 16 app router, React 19, TypeScript, Tailwind 3.4, TanStack Query v5, `@base-ui/react` (frndOS v2), PostHog (`posthog-js`), `bun test` (vitest-compatible API, jsdom preload), Testing Library.

**Spec:** `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md` — this plan implements §5 (Part A web) against the api contract in §4.5–4.6, under §11. Parts B, C and D are out of scope.

## Global Constraints

- **Where to work:** worktree `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item`, branch `feature/daffa/vc-client-lane-multi-item` (unpushed — continue on it). Every command below `cd`s into that literal path; agent shells reset cwd between calls. `bun install` and `.env.local` are already in place (verify in Task 0).
- **Git:** use `/usr/bin/git` and `/usr/bin/grep` (an rtk hook rewrites plain `git`/`grep` output). Shell is zsh: no word-splitting of `$F` — put file lists in arrays (`F=(a b); npx eslint "${F[@]}"`). Commits `<type>(web): …` ending with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. **Never push. Never `git stash`.**
- **Tests:** `bun test <file>` — ONE file per invocation; never a directory, never `bunx vitest`. Query with `within(document.body)`, never `screen`. bun has no `vi.waitFor`, `vi.hoisted`, `vi.mocked` — use RTL `waitFor` and cast spies (`as unknown as { mock: … }`). jsdom lacks `Range.getBoundingClientRect` (stub it on the prototype in try/finally when a mention editor receives "@") and does not reflect `contentEditable` (use `setAttribute`). Keep every test file < ~45 KB (past ~51 KB bun dies with a bogus SCSS error) — split files instead. Anything rendering `CommentComposer`/`CommentThread` needs a `QueryClientProvider` wrapper.
- **Mocks:** **never `vi.mock` a module** (bun's mock registry is process-global). Spy on the edges: `vi.spyOn(axiosInstance, "get"|"post")` (agency), `vi.spyOn(axiosPublic, "get"|"post")` (public), `vi.spyOn(globalThis, "fetch")` (`/s/session`), `vi.spyOn(posthog, "capture")` with `import posthog from "posthog-js"`. The only module mocks that exist are the ones already inside `KvSharePanel.test.tsx`; keep their factory shapes byte-identical. Consequence for code: anything `KvSharePanel` renders may import only `useClientLaneEnabled` from `@/lib/featureFlags`, only `trackKvShareLinkToggled` from `@/lib/analytics/kv-generator-events`, and must read toasts through `useToastStore((s) => s.showToast)` (that file mocks the store as a selector function — no `getState`).
- **Mutation check is mandatory:** after each new test passes, break the rule it guards exactly as the step says, run the test, watch the NAMED test fail, restore, watch it pass. If an expectation disagrees with what the code prints, fix the expectation only when the code matches the spec; otherwise fix the code.
- **Type gate:** `npx tsc --noEmit -p .` — baseline **895** errors (re-measured in Task 0). Touched files must have **0**: `npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "<touched paths regex>"` prints nothing. `npx eslint <touched files>` clean. `bunx prettier --write <touched files>` before each commit. `bun run build` is broken locally; if a build is ever needed: `node node_modules/next/dist/bin/next build`.
- **frndOS components first (spec §11):** before any UI task read `.agents/skills/frndos-ui/SKILL.md`, `frndos-components-v2/SKILL.md`, `frndos-design-foundations/SKILL.md` (§Appearance), `frndos-rules/SKILL.md`. Priority v2 → v1 → base → new v2. Use the §11.2 map: v2 `Button` everywhere (no new `BTN_*` uses), v1 `Label` for every status pill through ONE map `src/lib/client-lane/statusTone.ts`, v1 `Avatar` + `getInitials`/`getAvatarColor`, v2 `ItemRow` + v2 `ActionMenu` for request rows, v2 `Chip` for approvers, v2 `AutoGrowTextarea` for message/note, v2 `FilterChips` for phase pills (extended with multi-select in Task 2, story + skill row updated), v1 `DatePicker` for Decide by, v1 `ProgressBar` for "2 of 8 decided", the client-lane `Sheet` for client bottom sheets.
- **One file never imports both `@/components/frndos` (v1) and `@/components/frndos/v2`.** Ruling for the map's mixed surfaces: each v1 piece lives alone in a tiny client-lane wrapper (`StatusPill.tsx` → `Label`, `PersonAvatar.tsx` → `Avatar`, `DecideByField.tsx` → `DatePicker`, `RequestProgressBar.tsx` → `ProgressBar`), and v2 files import those wrappers, never v1 directly.
- **Tokens only** on every line this plan writes: `text-text-inverse*` / `text-text-default*`, `text-textXs` / `text-textXsMedium` / `text-textSm` / `text-textSmMedium`, `rounded-full|2xl|xl|lg|md`, `bg-white/5|10|15`, `border-white/10`, hairlines `border-white/5`, `font-geist`, `transition-all duration-200 ease-out`, `focus-visible:ring-2 focus-visible:ring-white/40`. Never `text-[Npx]`, `rounded-[Npx]`, `px-[Npx]`, `text-white`, `text-gray-*`, or a new dark hex. (The one arbitrary value allowed is the safe-area padding `pb-[max(env(safe-area-inset-bottom),1rem)]`, copied from `DecisionBar`.) Agency UI must read right in Midnight, Aurora and Daylight; `/s/` stays dark-scoped (`data-theme-scope="dark"` + `[data-client-lane-page]`) and nothing on it portals out of that subtree (so no `Popover`/`Tooltip`/`ActionMenu` on the client page).
- **Toasts** `useToastStore((s) => s.showToast)` with positional args (`title, description, type`). **Analytics** only through typed helpers in `src/lib/analytics/client-lane-events.ts` (never inline `posthog.capture`); public events are PII-free (no names, emails, tokens, lane codes).
- **Flag:** the agency side stays behind `show-client-lane` (`useClientLaneEnabled`); `/s/*` is unflagged and must render both C-1 shapes (with and without `request`) because the api deploys first.
- **Unchanged surfaces:** deck and campaign plan share sheets (`ApprovalStatusBlock`, `RequestApprovalPanel`) and deck / plan / KV-view / legacy-KV-round decision pages (`DecisionBar`, `HowBigSheet`) must behave exactly as before — each touched one gets a regression test.

## Review Focus

Five inputs the spec implies but its happy path does not exercise, most likely to bite first. Each has a named test in its owning task.

1. **A named approver who already answered an artboard that is still pending** (policy `required`, others still to decide). The card must read their own answer ("Approved"), progress must count it, and Approve all must not re-send it. → Task 7 `requestArtboards` "reads the viewer's own answer on a still-pending artboard"; Task 9 "counts the viewer's own answer on a still-pending artboard".
2. **Pins placed this visit on one artboard.** Approve all must skip that artboard (and say so in its label), and a card decision must carry only that artboard's pins, never pins on its neighbours. → Task 7 `approveAllPlan` tests; Task 9 "skips the pinned artboard in Approve all", "asks for a new version with this artboard's pins, at once".
3. **Replaced artboards** (superseded by a newer request, at load or in a decision response). Greyed "Replaced by a newer version", no ✓/✎, no pins, not in progress, not in Approve all. → Task 7 "greys a replaced artboard and offers it no decision"; Task 9 "leaves a replaced artboard out of progress and Approve all".
4. **Partial results after a race** (`skipped_closed` / `skipped_replaced` in C-3's `results`). The page must say nothing changed on those artboards and show the states the api returned, not claim success. → Task 9 "says when an artboard closed before the decision landed".
5. **An old request link after the request closed or was withdrawn** (the WhatsApp link "keeps showing that request, forever"). Final state per artboard, no decision controls, no Approve all, a withdrawn line. → Task 8 `RequestOutcomeBanner` tests; Task 9 "shows a withdrawn request read-only".

---

## File Structure

All paths relative to the web worktree root.

| File | Status | Responsibility |
|---|---|---|
| `docs/prd/client-lane-p0a/web.md` | modify | Multi-item contract notes replaced by the api plan's rewritten block (byte-identical with `api.md`) |
| `docs/tracks/client-lane-multi-item.track.md` | modify | Part A section: plan link, baselines, checklist, session log |
| `src/lib/client-lane/types.ts` | modify | `ApprovalRequestCounts`, `PublicRequest`, `PublicRequestApproval`, `request`/`approvals` on C-1, `RequestDecisionInput`/`Response`, `note_required` |
| `src/lib/client-lane/publicApi.ts` | modify | `postRequestDecision` |
| `src/lib/client-lane/storage.ts` | modify | `RequestDecisionDraft`; `readDraft`/`writeDraft` take either draft |
| `src/lib/client-lane/requests.ts` | create | `requestOf`, `plural`, agency row strings, `replacesNote`, `isoDayFromToday`, `buildRequestPayload` |
| `src/lib/client-lane/requests.test.ts` | create | Tests for `requests.ts` |
| `src/lib/client-lane/statusTone.ts` | create | The one status → Label map (`STATUS_TONE`, `OUTCOME_TONE`, `ARTBOARD_STATE_TONE`, `artboardStateOf`, `stateOfOutcome`) |
| `src/lib/client-lane/statusTone.test.ts` | create | Tests for the map |
| `src/lib/client-lane/versionLabels.ts` (+ test) | modify | `requestVersionLabels` |
| `src/lib/client-lane/testFixtures.ts` | modify | `requestApproval`, `publicRequest`, `kvRequest`, `agencyRequest`, `requestPreview`, `agencyDecision` |
| `src/services/client-lane.ts` (+ test) | modify | Request types, `v1/approval-requests` calls, keys, hooks; `useApprovalVersionLabels` reads requests for KV |
| `src/lib/analytics/client-lane-events.ts` | modify | §5.3 helpers; `trackApprovalModeToggled` removed |
| `src/components/frndos/v2/FilterChips.tsx` (+ new test) | modify | Optional multi-select mode |
| `src/components/frndos/stories/FilterChipsV2.stories.tsx` | modify | `MultiSelect` story |
| `.agents/skills/frndos-components-v2/SKILL.md` | modify | FilterChips row names the multi-select mode |
| `src/components/client-lane/StatusPill.tsx` | create | v1 `Label` pills: `StatusPill`, `OutcomePill`, `ApproverPill`, `ArtboardStatePill` |
| `src/components/client-lane/agency/PersonAvatar.tsx` | create | v1 `Avatar` face (lifted from `ApprovalStatusBlock`) |
| `src/components/client-lane/agency/DecisionRow.tsx` | create | `DecisionRow` + `DecisionList` (latest per person + earlier-answers fold), lifted |
| `src/components/client-lane/agency/ApprovalStatusBlock.tsx` (+ test) | modify | Uses the lifted pieces; pills become `Label` |
| `src/components/client-lane/agency/useApproverEmails.ts` | create | Approver email list state + validation + brand-client suggestions, shared |
| `src/components/client-lane/agency/RequestApprovalPanel.tsx` | modify | Uses `useApproverEmails`; `ApprovalSendStep` takes a `SendStepResult` + optional `headline` |
| `src/components/client-lane/agency/RequestApprovalPanel.test.tsx` | create | Deck / plan regression for the panel and its send step |
| `src/components/client-lane/agency/ApproverEmailsField.tsx` | create | v2 approver field (Chip + input + suggestions) |
| `src/components/client-lane/agency/DecideByField.tsx` | create | v1 DatePicker, alone |
| `src/components/client-lane/agency/KvRequestForm.tsx` (+ test) | create | The request form (v2) → send step |
| `src/components/client-lane/agency/KvApprovalRequestsSection.tsx` (+ test) | create | "Approval requests" section (v2): header button, rows, detail, Copy/Resend/Withdraw |
| `src/components/studio/kv-generator/ShareSectionLabel.tsx` | create | The dialog's `SectionLabel`, lifted so the section can use it |
| `src/components/studio/kv-generator/KvSharePanel.tsx` (+ test) | modify | Two sections; toggle and KV status block removed; form access-only |
| `src/components/client-lane/kv/roundItems.ts` | modify | Export `findInDocument` |
| `src/components/client-lane/kv/requestItems.ts` (+ test) | create | `RequestArtboard` model, progress, Approve-all plan, next undecided, labels |
| `src/components/client-lane/kv/KvPhaseGrid.tsx` | modify | Optional per-card `badge`, `actions`, `muted`; `columns` |
| `src/components/client-lane/kv/KvFocusedItem.tsx` | modify | Optional `noun` ("artboards") |
| `src/components/client-lane/kv/KvRequestHero.tsx` (+ test) | create | Request grid (state pill, ✓/✎ per card) ↔ focused view |
| `src/components/client-lane/RequestProgressBar.tsx` | create | v1 ProgressBar, alone |
| `src/components/client-lane/RequestRail.tsx` (+ test) | create | `RequestOverview`, `RequestOutcomeBanner`, `FocusedArtboardPanel`, `RequestActionBar` |
| `src/components/client-lane/sheets/NewVersionNoteSheet.tsx` | create | "What should change?" (required note) |
| `src/components/client-lane/DecisionPage.tsx` | modify | Request branch: model, decisions by `approval_ids`, rail, sheets, analytics |
| `src/components/client-lane/DecisionPage.request.test.tsx` | create | Page tests for a request link |
| `src/components/client-lane/DecisionPage.regression.test.tsx` | create | Deck round + KV view link unchanged |
| `src/lib/client-lane/round.ts` (+ test) | modify | Title / alt / OG pill name the request |
| `src/app/s/[token]/page.tsx`, `src/app/s/[token]/opengraph-image.tsx` | modify | Request message as description; OG pill + "Request n" |

---

### Task 0: Baselines, contract copy, track file

**Files:**
- Modify: `docs/prd/client-lane-p0a/web.md` (the `### Additive notes (multi-item approval rounds — …)` block, lines 153–165)
- Modify: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:** none (setup + docs).

- [ ] **Step 1: Confirm the worktree**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git branch --show-current && /usr/bin/git status --short && /usr/bin/git log --oneline -1 && ls -la .env.local node_modules/.bin/next
```

Expected: `feature/daffa/vc-client-lane-multi-item`, an empty status, tip `6d5531e31` or newer, both paths exist. A dirty tree → stop and ask Daffa (never stash).

- [ ] **Step 2: Record baselines**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected `895`. Then, one per invocation, note pass counts:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/ApprovalStatusBlock.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvRoundHero.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvLinkGallery.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/brands/campaign-planner/SharePlanDialog.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/round.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/versionLabels.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/services/client-lane.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/frndos/v2/PageToolbar.test.tsx
```

Expected: all pass (the track file's last log lists the counts). A failure here is pre-existing — record it; do not fix.

- [ ] **Step 3: Copy the contract notes from the api plan, verbatim**

The binding block is the ````` ````markdown ````` fence of **Task 1** in `/Users/alva.e202511001/Desktop/work/frndos-agentic/docs/superpowers/plans/2026-10-01-client-lane-kv-approval-requests-api.md` (lines ~196–228; heading `### Additive notes (KV approval requests — spec …, 2026-10-01)`). Extract it, splice it into `web.md` in place of the whole multi-item section (its heading through the last bullet before `## Scope`, lines 153–165), with one blank line before `## Scope` — exactly what api Task 1 does to `api.md`:

```bash
API_PLAN=/Users/alva.e202511001/Desktop/work/frndos-agentic/docs/superpowers/plans/2026-10-01-client-lane-kv-approval-requests-api.md
WEB_MD=/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item/docs/prd/client-lane-p0a/web.md
TMP=$(mktemp -d)
awk '/^````markdown$/{f=1; next} /^````$/{f=0} f' "$API_PLAN" > "$TMP/block.md" && head -1 "$TMP/block.md" && wc -l "$TMP/block.md"
python3 - "$WEB_MD" "$TMP/block.md" <<'PY2'
import sys
path, block_path = sys.argv[1], sys.argv[2]
text = open(path).read()
block = open(block_path).read()
start = text.index("### Additive notes (multi-item approval rounds")
end = text.index("\n## Scope") + 1
text = text[:start] + block + "\n" + text[end:]
open(path, "w").write(text)
section = text[text.index("### Additive notes (KV approval requests"):text.index("\n## Scope") + 1]
assert section == block + "\n", "web.md section differs from the api plan block"
print("IDENTICAL to the api plan block")
PY2
```

Expected: the first line printed is `### Additive notes (KV approval requests — spec …`, the block is ~32 lines, and `IDENTICAL to the api plan block`. Never edit the copied text — a disagreement is raised with Daffa.

Once the api worktree has committed its Task 1, prove the two PRD copies are byte-identical:

```bash
API_MD=/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item/docs/prd/client-lane-p0a/api.md
WEB_MD=/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item/docs/prd/client-lane-p0a/web.md
sect() { awk '/^### Additive notes \(KV approval requests/{p=1} /^## Scope/{p=0} p' "$1"; }
diff <(sect "$API_MD") <(sect "$WEB_MD") && echo PRD-COPIES-IDENTICAL
```

Expected: `PRD-COPIES-IDENTICAL`. If api Task 1 has not landed yet, write "api.md diff pending" under the track file's Open list and re-run this diff in Task 11 Step 2.

- [ ] **Step 4: Update the track file**

In `docs/tracks/client-lane-multi-item.track.md`: change the frontmatter `parent_prd:` to `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md`; in the Status table set `Spec` to `superseded by 2026-10-01 KV approval requests (Part A in progress)` and `Implementation` to `in_progress — Part A`. Insert before `## Session Log`:

```markdown
## Part A — KV approval requests (plan `docs/superpowers/plans/2026-10-01-client-lane-kv-approval-requests-web.md`)

Part A base (`BASE`, the tip printed by Step 1, before this task's commit): <sha>. Baselines (Task 0): tsc <number from Step 2>; pre-existing test failures: <none | list>.

- [x] Task 0: baselines, contract notes, this section
- [ ] Task 1: wire types, services, request + tone helpers
- [ ] Task 2: v2 FilterChips multi-select
- [ ] Task 3: shared agency pieces (Label pills, avatar, decision rows, approver emails, send step)
- [ ] Task 4: KvRequestForm
- [ ] Task 5: KvApprovalRequestsSection
- [ ] Task 6: KvSharePanel — two sections, toggle removed
- [ ] Task 7: request model + KvRequestHero
- [ ] Task 8: RequestRail + note sheet
- [ ] Task 9: DecisionPage request branch
- [ ] Task 10: title, description and OG card for request links
- [ ] Task 11: gates, smoke, tri-mode, Lark taxonomy
```

Append to the Session Log:

```markdown
### 2026-10-01 — daffa (plan executor)
- Part A Task 0: baselines recorded; contract notes copied from <api.md | the api plan file> and diffed IDENTICAL.
```

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add docs/prd/client-lane-p0a/web.md docs/tracks/client-lane-multi-item.track.md && /usr/bin/git commit -m "$(cat <<'EOF'
docs(web): contract notes + track for KV approval requests

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1: Wire types, services, request + tone helpers

**Files:**
- Modify: `src/lib/client-lane/types.ts` (imports line 6-9; after `ApprovalRound` line 87; `ShareLinkBase` after `items` line 135; after `DecisionResponse` line 200; `PublicErrorCode` line 217-222)
- Modify: `src/lib/client-lane/publicApi.ts`, `src/lib/client-lane/storage.ts`, `src/lib/client-lane/versionLabels.ts`, `src/lib/client-lane/testFixtures.ts`, `src/services/client-lane.ts`
- Create: `src/lib/client-lane/requests.ts`, `src/lib/client-lane/requests.test.ts`, `src/lib/client-lane/statusTone.ts`, `src/lib/client-lane/statusTone.test.ts`
- Test: `src/lib/client-lane/versionLabels.test.ts`, `src/services/client-lane.test.ts` → renamed `client-lane.test.tsx`

**Interfaces:**
- Consumes: `PublicKvItem` (`@/services/query`), `KvSharePhase` (`@/types/kv/share-link`), `LabelVariant` (`@/components/frndos/Label`), `STATUS_LABEL` / `deferralDate` (`lib/client-lane/format.ts`).
- Produces (later tasks use these exact names):
  - types: `ApprovalRequestCounts`, `PublicRequestApprover`, `PublicRequest`, `PublicRequestApproval`, `ShareLinkBase.request?: PublicRequest | null`, `ShareLinkBase.approvals?: PublicRequestApproval[]`, `RequestDecisionOutcome`, `RequestDecisionInput`, `RequestDecisionResultCode`, `RequestDecisionResult`, `RequestDecisionResponse`; `PublicErrorCode` gains `"note_required"`.
  - `postRequestDecision(token: string, input: RequestDecisionInput, laneCode?: string | null): Promise<RequestDecisionResponse>`
  - `RequestDecisionDraft = Omit<RequestDecisionInput, "guest_name" | "guest_email">`; `readDraft<T extends { outcome: string } = DecisionDraft>(token): T | null`; `writeDraft(token, draft: DecisionDraft | RequestDecisionDraft)`
  - `requests.ts`: `RequestView { request; approvals }`, `requestOf(data: ShareLinkData): RequestView | null`, `plural(n, one, many?)`, `requestArtboardTotal(r)`, `requestTitle(r)`, `requestRowDescription(r)`, `replacesNote(item)`, `isoDayFromToday(n)`, `buildRequestPayload({ phases, emails, message, decideBy }): CreateApprovalRequestInput`
  - `statusTone.ts`: `Tone { variant: LabelVariant; label: string }`, `STATUS_TONE`, `OUTCOME_TONE`, `ArtboardState`, `ARTBOARD_STATE_TONE`, `artboardStateOf(status, replaced)`, `stateOfOutcome(outcome)`
  - `ShareVersion.type` gains `"approval_request"` (a request link's `version.label` is "Request {n}")
  - services: `AgencyRequestApproval`, `AgencyRequestApprover`, `AgencyRequest` (`share_url: string | null`), `ApprovalRequestPreviewItem`, `ApprovalRequestPreview` (`items`, `already_approved` and `waiting` all carry `phase`; `waiting` adds `request_number`), `CreateApprovalRequestInput`, `CreateApprovalRequestResponse`, `approvalRequestsRoot(fileId)`, `approvalRequestsKey(fileId)`, `approvalRequestPreviewKey(fileId)`, `previewApprovalRequest(fileId)`, `listApprovalRequests(fileId)`, `createApprovalRequest(fileId, input)`, `withdrawApprovalRequest(id)`, `resendApprovalRequest(id)`, `useApprovalRequestPreview(fileId, { enabled? })`, `useApprovalRequests(fileId, { enabled? })`, `useCreateApprovalRequest(fileId)`, `useWithdrawApprovalRequest(fileId)`, `useResendApprovalRequest()`
  - `requestVersionLabels(requests: Pick<AgencyRequest, "approvals">[]): Map<string, string>`
  - fixtures: `requestApproval()`, `publicRequest()`, `kvRequest()`, `agencyDecision()`, `agencyRequest()`, `requestPreview()`

- [ ] **Step 1: Extend the public wire types**

In `src/lib/client-lane/types.ts`, `ShareVersion.type` (lines 28-34) gains `| "approval_request"` — C-1 of a request link sends `version = { type: "approval_request", id: <request id>, label: "Request {n}", created_at: <sent_at> }`. Then add after line 9 (`import type { DeckDocument } …`):

```ts
import type { KvSharePhase } from "@/types/kv/share-link";
```

Insert after `ApprovalRound` (ends line 87):

```ts

/** Per-request tallies — C-1 `request.counts` and the agency list's `counts`. */
export interface ApprovalRequestCounts {
  approved: number;
  approved_with_changes: number;
  changes_required: number;
  pending: number;
  /** Artboards a newer request took over (they no longer count here). */
  superseded: number;
}

export interface PublicRequestApprover {
  name: string;
  decided: boolean;
}

/**
 * A KV approval request as its own link shows it (C-1 `request`, spec
 * 2026-10-01 §4.6). The link shows this request forever — including its
 * final state — so every field is read, never assumed pending.
 */
export interface PublicRequest {
  id: string;
  number: number;
  status: ApprovalStatus;
  message: string | null;
  /** `YYYY-MM-DD` (or a timestamp) — the day the agency asked for answers by. */
  decide_by: string | null;
  /** "I need more time" — request-level (spec D-6). */
  deferred_until: string | null;
  deferred_note: string | null;
  approvers: PublicRequestApprover[];
  counts: ApprovalRequestCounts;
}

/**
 * One artboard of a request (C-1 `approvals[]`): its own approval, its own
 * round. `snapshot` is the item exactly as rendered at send time;
 * `version_id` is what its pins anchor on.
 */
export interface PublicRequestApproval {
  id: string;
  phase: KvSharePhase;
  label: string;
  round: number;
  version_id: string;
  status: ApprovalStatus;
  snapshot: PublicKvItem | null;
  /** A newer request superseded it: greyed, never decidable. */
  replaced: boolean;
  decisions: ApprovalDecision[];
}
```

In `ShareLinkBase`, after the `items: ApprovalItem[];` member (line 135) add:

```ts
  /**
   * A request link (`share_links.purpose = approval`): the request it was
   * sent for, with `approval: null`. Absent / null on deck, plan and view
   * links and on an api that predates requests — read it through
   * `requestOf()` (lib/client-lane/requests.ts), never directly.
   */
  request?: PublicRequest | null;
  /** The request's artboards in request order; absent unless `request`. */
  approvals?: PublicRequestApproval[];
```

Insert after `DecisionResponse` (ends line 200):

```ts

export type RequestDecisionOutcome = "approved" | "changes_required" | "deferred";

/** C-3 for a request link: decisions name the artboards they are on. */
export interface RequestDecisionInput {
  /** 1..50 ids of this request's approvals; omitted for `deferred`. */
  approval_ids?: string[];
  outcome: RequestDecisionOutcome;
  note?: string;
  /** This visit's pins; the api keeps, per approval, only those on its version. */
  pins?: string[];
  deferred_until?: string;
  guest_name?: string;
  guest_email?: string;
}

export type RequestDecisionResultCode =
  "decided" | "skipped_closed" | "skipped_replaced";

export interface RequestDecisionResult {
  approval_id: string;
  result: RequestDecisionResultCode;
  decision: ApprovalDecision | null;
}

export interface RequestDecisionResponse {
  results: RequestDecisionResult[];
  request: PublicRequest;
  approvals: PublicRequestApproval[];
}
```

In `PublicErrorCode` add `| "note_required"` after `| "magic_link_expired"`.

- [ ] **Step 2: The public call and the draft type**

Append to `src/lib/client-lane/publicApi.ts` after `postDecision` (line 74), and add `RequestDecisionInput, RequestDecisionResponse` to its type import:

```ts
/**
 * C-3 on a request link (spec 2026-10-01 §4.6): one decision per artboard,
 * named by `approval_ids`. Same `{ data }` envelope as a round decision.
 */
export async function postRequestDecision(
  token: string,
  input: RequestDecisionInput,
  laneCode?: string | null
): Promise<RequestDecisionResponse> {
  const res = await axiosPublic.post<{ data: RequestDecisionResponse }>(
    `public/share-links/${encodeURIComponent(token)}/decision`,
    input,
    { headers: laneHeaders(laneCode) }
  );
  return res.data.data;
}
```

In `src/lib/client-lane/storage.ts`, line 7 becomes:

```ts
import type { DecisionInput, GuestIdentity, RequestDecisionInput } from "./types";
```

After `export type DecisionDraft = …` (line 47) add:

```ts

/** The same interrupted decision on a request link (approval ids, not a round). */
export type RequestDecisionDraft = Omit<
  RequestDecisionInput,
  "guest_name" | "guest_email"
>;
```

Change `readDraft`'s signature (line 49) and its two casts:

```ts
export function readDraft<T extends { outcome: string } = DecisionDraft>(
  token: string
): T | null {
  try {
    const raw = window.sessionStorage.getItem(draftStorageKey(token));
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<T>;
    if (typeof parsed.outcome !== "string") return null;
    return parsed as T;
  } catch {
    return null;
  }
}
```

and `writeDraft`'s parameter (line 61) to `draft: DecisionDraft | RequestDecisionDraft`.

- [ ] **Step 3: Agency types, calls and hooks**

In `src/services/client-lane.ts` replace the type import (lines 10-15) with:

```ts
import type {
  Approval,
  ApprovalDecision,
  ApprovalItemPhase,
  ApprovalPolicy,
  ApprovalRequestCounts,
  ApprovalStatus,
  ShareSubjectType,
} from "@/lib/client-lane/types";
```

and line 18 with:

```ts
import {
  approvalVersionLabels,
  requestVersionLabels,
} from "@/lib/client-lane/versionLabels";
```

Insert before `/* ── Hooks ──…` (line 154):

```ts
/* ── KV approval requests (spec 2026-10-01 §4.5) ───────────────────────── */

/** One artboard of a request as `GET v1/approval-requests` lists it. */
export interface AgencyRequestApproval {
  id: string;
  subject_key: string;
  phase: KvSharePhase;
  label: string;
  /** This artboard's own round (1, 2, …). */
  round: number;
  version_id: string;
  thumbnail_url: string | null;
  status: ApprovalStatus;
  /** Set once a newer request took this artboard over. */
  superseded_by_request_number: number | null;
  /** Client pins on this version since the approval was created. */
  pin_count: number;
  decisions: ApprovalDecision[];
}

export interface AgencyRequestApprover {
  name: string;
  email: string;
  user_id: string | null;
  /** Null while the request's link or the approver's lane is not active. */
  personal_url: string | null;
  decided: boolean;
}

export interface AgencyRequest {
  id: string;
  number: number;
  status: ApprovalStatus;
  policy: ApprovalPolicy;
  message: string | null;
  sent_at: string | null;
  decide_by: string | null;
  deferred_until: string | null;
  deferred_note: string | null;
  resolved_at: string | null;
  created_at: string | null;
  /** The request's own link (`purpose = approval`), never a view link;
   *  `null` when it has none. */
  share_url: string | null;
  share_link_active: boolean;
  counts: ApprovalRequestCounts;
  approvers: AgencyRequestApprover[];
  approvals: AgencyRequestApproval[];
}

export interface ApprovalRequestPreviewItem {
  subject_key: string;
  phase: KvSharePhase;
  label: string;
  version_id: string;
  thumbnail_url: string | null;
  /** Still waiting in another request — sending this one replaces it. */
  replaces: { request_number: number; round: number } | null;
}

/** `GET v1/approval-requests/preview`: what a request would contain now. */
export interface ApprovalRequestPreview {
  phases: Array<{ phase: KvSharePhase; count: number }>;
  items: ApprovalRequestPreviewItem[];
  /** Same version already approved — never re-sent. */
  already_approved: Array<{
    subject_key: string;
    phase: KvSharePhase;
    label: string;
    version_id: string;
  }>;
  /** Same version still pending in another request (api ruling R2): the
   *  identical artwork is never re-sent, so it is listed, not sendable. */
  waiting: Array<{
    subject_key: string;
    phase: KvSharePhase;
    label: string;
    version_id: string;
    request_number: number;
  }>;
  /** Number of `items`. */
  total: number;
}

export interface CreateApprovalRequestInput {
  kv_phases: KvSharePhase[];
  approver_emails: string[];
  message?: string;
  /** `YYYY-MM-DD`, a future day. */
  decide_by?: string;
}

export interface CreateApprovalRequestResponse {
  request: AgencyRequest;
  share_url: string;
  approvers: CreateApprovalResponse["approvers"];
}

/** Every request query on a file shares this prefix, so one invalidation
 *  refreshes the list AND the preview. */
export const approvalRequestsRoot = (fileId: string) =>
  ["approval-requests", "kv_file", fileId] as const;
export const approvalRequestsKey = (fileId: string) =>
  [...approvalRequestsRoot(fileId), "list"] as const;
export const approvalRequestPreviewKey = (fileId: string) =>
  [...approvalRequestsRoot(fileId), "preview"] as const;

const kvSubject = (fileId: string) => ({
  subject_type: "kv_file" as const,
  subject_id: fileId,
});

export async function previewApprovalRequest(
  fileId: string
): Promise<ApprovalRequestPreview> {
  const res = await axiosInstance.get<{ data: ApprovalRequestPreview }>(
    "v1/approval-requests/preview",
    { params: kvSubject(fileId) }
  );
  return res.data.data;
}

/** Every request on the file — open first, then newest first (api order). */
export async function listApprovalRequests(
  fileId: string
): Promise<AgencyRequest[]> {
  const res = await axiosInstance.get<{ data: AgencyRequest[] }>(
    "v1/approval-requests",
    { params: kvSubject(fileId) }
  );
  return res.data.data;
}

export async function createApprovalRequest(
  fileId: string,
  input: CreateApprovalRequestInput
): Promise<CreateApprovalRequestResponse> {
  const res = await axiosInstance.post<{ data: CreateApprovalRequestResponse }>(
    "v1/approval-requests",
    { ...kvSubject(fileId), ...input }
  );
  return res.data.data;
}

export async function withdrawApprovalRequest(
  id: string
): Promise<AgencyRequest> {
  const res = await axiosInstance.post<{ data: AgencyRequest }>(
    `v1/approval-requests/${id}/withdraw`
  );
  return res.data.data;
}

export async function resendApprovalRequest(id: string): Promise<string[]> {
  const res = await axiosInstance.post<{ sent: string[] }>(
    `v1/approval-requests/${id}/resend`
  );
  return res.data.sent;
}
```

Append after `useResendApproval` (line 208):

```ts

export function useApprovalRequestPreview(
  fileId: string | null | undefined,
  opts: { enabled?: boolean } = {}
) {
  return useQuery({
    queryKey: approvalRequestPreviewKey(fileId ?? ""),
    queryFn: () => previewApprovalRequest(fileId as string),
    enabled: Boolean(fileId) && (opts.enabled ?? true),
    staleTime: 15_000,
  });
}

export function useApprovalRequests(
  fileId: string | null | undefined,
  opts: { enabled?: boolean } = {}
) {
  return useQuery({
    queryKey: approvalRequestsKey(fileId ?? ""),
    queryFn: () => listApprovalRequests(fileId as string),
    enabled: Boolean(fileId) && (opts.enabled ?? true),
    staleTime: 15_000,
  });
}

export function useCreateApprovalRequest(fileId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: CreateApprovalRequestInput) =>
      createApprovalRequest(fileId, input),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: approvalRequestsRoot(fileId) });
    },
  });
}

export function useWithdrawApprovalRequest(fileId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => withdrawApprovalRequest(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: approvalRequestsRoot(fileId) });
    },
  });
}

export function useResendApprovalRequest() {
  return useMutation({ mutationFn: (id: string) => resendApprovalRequest(id) });
}
```

Replace `useApprovalVersionLabels` (lines 210-225) with:

```ts
/**
 * `versionLabelById` for a subject's comment panel: every frozen version →
 * "v{round}". Decks and plans read their rounds (`GET v1/approvals`); a KV
 * file reads its requests (spec 2026-10-01 — `GET v1/approvals` answers only
 * legacy rows for `kv_file`), where the round is the artboard's own. Empty
 * until loaded, and when disabled (flag off).
 */
export function useApprovalVersionLabels(
  subjectType: ShareSubjectType,
  subjectId: string | null | undefined,
  opts: { enabled?: boolean } = {}
): ReadonlyMap<string, string> {
  const enabled = opts.enabled ?? true;
  const isKv = subjectType === "kv_file";
  const approvals = useApprovals(subjectType, subjectId, {
    enabled: enabled && !isKv,
  });
  const requests = useApprovalRequests(isKv ? subjectId : null, { enabled });
  return useMemo(() => {
    const out = approvalVersionLabels(approvals.data?.data ?? []);
    for (const [id, label] of requestVersionLabels(requests.data ?? [])) {
      if (!out.has(id)) out.set(id, label);
    }
    return out;
  }, [approvals.data, requests.data]);
}
```

- [ ] **Step 4: Fixtures**

In `src/lib/client-lane/testFixtures.ts` extend the imports:

```ts
import type {
  AgencyRequest,
  ApprovalRequestPreview,
} from "@/services/client-lane";
import type { KvSharePhase } from "@/types/kv/share-link";

import type {
  Approval,
  ApprovalDecision,
  ApprovalItem,
  ApprovalItemPhase,
  PublicComment,
  PublicRequest,
  PublicRequestApproval,
  ShareLinkKv,
} from "./types";
```

(the `./types` import replaces the existing one at lines 12-18) and append:

```ts

/* ── KV approval requests (spec 2026-10-01) ──────────────────────────── */

/** One artboard of a request; its snapshot IS the rendered item. */
export function requestApproval(
  snapshot: PublicKvItem,
  phase: KvSharePhase,
  overrides: Partial<PublicRequestApproval> = {}
): PublicRequestApproval {
  return {
    id: `ra_${snapshot.id}`,
    phase,
    label: `${phase} · ${snapshot.id}`,
    round: 1,
    version_id: snapshot.id,
    status: "pending",
    snapshot,
    replaced: false,
    decisions: [],
    ...overrides,
  };
}

export function publicRequest(
  overrides: Partial<PublicRequest> = {}
): PublicRequest {
  return {
    id: "rq2",
    number: 2,
    status: "pending",
    message: "Three artboards ready",
    // The api stores the end of that day (app timezone) and returns ISO.
    decide_by: "2026-10-03T23:59:59+07:00",
    deferred_until: null,
    deferred_note: null,
    approvers: [],
    counts: {
      approved: 0,
      approved_with_changes: 0,
      changes_required: 0,
      pending: 3,
      superseded: 0,
    },
    ...overrides,
  };
}

/**
 * A request link (C-1 with `purpose = approval`): Request 2 over the Craft
 * board and two Resize tiles, open, seen by Dina on her personal lane.
 * `items` mirrors `approvals`, as the api sends it.
 */
export function kvRequest(overrides: Partial<ShareLinkKv> = {}): ShareLinkKv {
  const approvals = overrides.approvals ?? [
    requestApproval(HERO, "craft"),
    requestApproval(STORY, "resize"),
    requestApproval(FEED, "resize"),
  ];
  return kvRound({
    approval: null,
    request: publicRequest(),
    version: {
      type: "approval_request",
      id: "rq2",
      label: "Request 2",
      created_at: "2026-10-01T08:00:00.000Z",
    },
    items: approvals.map((a) => ({
      id: a.id,
      phase: a.phase,
      label: a.label,
      version_id: a.version_id,
      status: a.status,
      snapshot: a.snapshot,
    })),
    ...overrides,
    approvals,
  });
}

export function agencyDecision(
  overrides: Partial<ApprovalDecision> = {}
): ApprovalDecision {
  return {
    id: "d1",
    actor: "Dina",
    outcome: "approved",
    note: null,
    pins: [],
    decided_at: "2026-10-01T09:00:00.000Z",
    advisory: false,
    deferred_until: null,
    item_id: null,
    ...overrides,
  };
}

/** Request 2 on the agency list: the Craft board approved, one Resize tile waiting on Dina. */
export function agencyRequest(
  overrides: Partial<AgencyRequest> = {}
): AgencyRequest {
  return {
    id: "rq2",
    number: 2,
    status: "pending",
    policy: "required",
    message: "Craft 1 · Resize 1",
    sent_at: "2026-10-01T08:00:00.000Z",
    decide_by: "2026-10-03T23:59:59+07:00",
    deferred_until: null,
    deferred_note: null,
    resolved_at: null,
    created_at: "2026-10-01T08:00:00.000Z",
    share_url: "https://frndos.test/s/req_tok",
    share_link_active: true,
    counts: {
      approved: 1,
      approved_with_changes: 0,
      changes_required: 0,
      pending: 1,
      superseded: 0,
    },
    approvers: [
      {
        name: "Dina",
        email: "dina@brand.co.id",
        user_id: "u9",
        personal_url: "https://frndos.test/s/req_tok?k=lanecode",
        decided: false,
      },
    ],
    approvals: [
      {
        id: "ap_g1",
        subject_key: "board:g0",
        phase: "craft",
        label: "Craft · Hero board",
        round: 1,
        version_id: "g1",
        thumbnail_url: "https://cdn.test/g1.png",
        status: "approved",
        superseded_by_request_number: null,
        pin_count: 0,
        decisions: [agencyDecision()],
      },
      {
        id: "ap_r1",
        subject_key: "resize:r1",
        phase: "resize",
        label: "Resize · IG Story · 1080×1920",
        round: 2,
        version_id: "r1",
        thumbnail_url: null,
        status: "pending",
        superseded_by_request_number: null,
        pin_count: 2,
        decisions: [],
      },
    ],
    ...overrides,
  };
}

/** What a new request would hold: Craft 1, Resize 2 (one replacing an older
 *  version waiting in Request 1); the Motion clip already approved; the IG
 *  Story tile waiting in Request 1 on the same version. */
export function requestPreview(
  overrides: Partial<ApprovalRequestPreview> = {}
): ApprovalRequestPreview {
  return {
    phases: [
      { phase: "craft", count: 1 },
      { phase: "resize", count: 2 },
    ],
    items: [
      {
        subject_key: "board:g0",
        phase: "craft",
        label: "Craft · Hero board",
        version_id: "g1",
        thumbnail_url: "https://cdn.test/g1.png",
        replaces: null,
      },
      {
        subject_key: "resize:r1",
        phase: "resize",
        label: "Resize · TikTok · 1080×1920",
        version_id: "r1",
        thumbnail_url: null,
        replaces: { request_number: 1, round: 1 },
      },
      {
        subject_key: "resize:r2",
        phase: "resize",
        label: "Resize · IG Feed · 1080×1080",
        version_id: "r2",
        thumbnail_url: null,
        replaces: null,
      },
    ],
    already_approved: [
      {
        subject_key: "motion:p1:9:16",
        phase: "motion",
        label: "Motion · 9:16 · 1080×1920",
        version_id: "m1",
      },
    ],
    waiting: [
      {
        subject_key: "resize:r3",
        phase: "resize",
        label: "Resize · IG Story · 1080×1920",
        version_id: "r3",
        request_number: 1,
      },
    ],
    total: 3,
    ...overrides,
  };
}
```

- [ ] **Step 5: Write the failing helper tests**

Create `src/lib/client-lane/requests.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  agencyRequest,
  kvRequest,
  kvRound,
  requestPreview,
} from "./testFixtures";
import {
  buildRequestPayload,
  isoDayFromToday,
  plural,
  replacesNote,
  requestOf,
  requestRowDescription,
  requestTitle,
} from "./requests";
import type { ShareLinkData } from "./types";

describe("requestOf", () => {
  it("reads a request link's request and artboards", () => {
    const view = requestOf(kvRequest());
    expect(view?.request.number).toBe(2);
    expect(view?.approvals.map((a) => a.id)).toEqual([
      "ra_g1",
      "ra_r1",
      "ra_r2",
    ]);
  });

  it("is null for a round link and for a response without the key", () => {
    expect(requestOf(kvRound())).toBeNull();
    const old = kvRound() as Partial<ShareLinkData>;
    delete old.request;
    expect(requestOf(old as ShareLinkData)).toBeNull();
  });

  it("never treats a deck or plan link as a request, whatever it carries", () => {
    const deck = {
      ...kvRequest(),
      type: "deck",
    } as unknown as ShareLinkData;
    expect(requestOf(deck)).toBeNull();
  });

  it("reads missing approvals as none rather than crashing", () => {
    const data = kvRequest();
    delete (data as { approvals?: unknown }).approvals;
    expect(requestOf(data)?.approvals).toEqual([]);
  });
});

describe("agency row strings", () => {
  it("titles a request by its live artboards", () => {
    expect(requestTitle(agencyRequest())).toBe("Request 2 · 2 artboards");
    const one = agencyRequest({
      approvals: [
        {
          ...agencyRequest().approvals[1],
          superseded_by_request_number: 3,
        },
        agencyRequest().approvals[0],
      ],
    });
    expect(requestTitle(one)).toBe("Request 2 · 1 artboard");
  });

  it("says who an open request waits on and by when", () => {
    expect(requestRowDescription(agencyRequest())).toMatch(
      /^Waiting on Dina · Decide by .+$/
    );
  });

  it("counts decisions when nobody is named", () => {
    expect(
      requestRowDescription(agencyRequest({ approvers: [], decide_by: null }))
    ).toBe("1/2 decided");
  });

  it("prefers the client's 'more time' date over the deadline", () => {
    expect(
      requestRowDescription(
        agencyRequest({ deferred_until: "2026-10-08" })
      )
    ).toMatch(/^Waiting on Dina · More time until .+$/);
  });

  it("reads a closed request as its result", () => {
    const counts = {
      approved: 5,
      approved_with_changes: 0,
      changes_required: 1,
      pending: 0,
      superseded: 0,
    };
    const six = Array.from({ length: 6 }, (_, i) => ({
      ...agencyRequest().approvals[1],
      id: `a${i}`,
    }));
    expect(
      requestRowDescription(
        agencyRequest({ status: "changes_required", counts, approvals: six })
      )
    ).toBe("Changes · 5/6");
    expect(
      requestRowDescription(
        agencyRequest({
          status: "approved",
          counts: { ...counts, approved: 6, changes_required: 0 },
          approvals: six,
        })
      )
    ).toBe("Approved · 6/6");
    expect(
      requestRowDescription(agencyRequest({ status: "not_relevant" }))
    ).toBe("Withdrawn");
  });
});

describe("form helpers", () => {
  it("names what a waiting artboard replaces", () => {
    const [, tiktok, feed] = requestPreview().items;
    expect(replacesNote(tiktok)).toBe(
      "Resize · TikTok · 1080×1920 — replaces v1, still waiting"
    );
    expect(replacesNote(feed)).toBeNull();
  });

  it("builds the POST body: trimmed message, deadline only when set", () => {
    expect(
      buildRequestPayload({
        phases: ["craft", "resize"],
        emails: ["dina@brand.co.id"],
        message: "  Smaller logo  ",
        decideBy: "2026-10-03",
      })
    ).toEqual({
      kv_phases: ["craft", "resize"],
      approver_emails: ["dina@brand.co.id"],
      message: "Smaller logo",
      decide_by: "2026-10-03",
    });
    expect(
      buildRequestPayload({
        phases: ["craft"],
        emails: [],
        message: "   ",
        decideBy: "",
      })
    ).toEqual({ kv_phases: ["craft"], approver_emails: [] });
  });

  it("writes a local YYYY-MM-DD n days out", () => {
    expect(isoDayFromToday(1)).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(isoDayFromToday(1) > isoDayFromToday(0)).toBe(true);
  });

  it("pluralises", () => {
    expect(plural(1, "artboard")).toBe("1 artboard");
    expect(plural(3, "artboard")).toBe("3 artboards");
  });
});
```

Create `src/lib/client-lane/statusTone.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  ARTBOARD_STATE_TONE,
  OUTCOME_TONE,
  STATUS_TONE,
  artboardStateOf,
  stateOfOutcome,
} from "./statusTone";

describe("statusTone", () => {
  it("gives every status one Label variant and the shared label", () => {
    expect(STATUS_TONE.pending).toEqual({ variant: "alert", label: "Pending" });
    expect(STATUS_TONE.approved.variant).toBe("success");
    expect(STATUS_TONE.approved_with_changes.variant).toBe("success");
    expect(STATUS_TONE.changes_required).toEqual({
      variant: "error",
      label: "Changes requested",
    });
    expect(STATUS_TONE.not_relevant).toEqual({
      variant: "neutral",
      label: "Withdrawn",
    });
    expect(OUTCOME_TONE.deferred.variant).toBe("alert");
  });

  it("names an artboard's state in the client's words", () => {
    expect(ARTBOARD_STATE_TONE.undecided.label).toBe("No decision yet");
    expect(ARTBOARD_STATE_TONE.approved_with_fixes.label).toBe(
      "Approved with fixes"
    );
    expect(ARTBOARD_STATE_TONE.new_version_asked.label).toBe(
      "New version asked"
    );
    expect(ARTBOARD_STATE_TONE.replaced.label).toBe(
      "Replaced by a newer version"
    );
  });

  it("reads 'replaced' before the status a superseded approval carries", () => {
    expect(artboardStateOf("not_relevant", true)).toBe("replaced");
    expect(artboardStateOf("not_relevant", false)).toBe("withdrawn");
    expect(artboardStateOf("pending", false)).toBe("undecided");
    expect(artboardStateOf("approved_with_changes", false)).toBe(
      "approved_with_fixes"
    );
    expect(artboardStateOf("changes_required", false)).toBe(
      "new_version_asked"
    );
  });

  it("maps a viewer's own outcome; a deferral is no artboard answer", () => {
    expect(stateOfOutcome("approved")).toBe("approved");
    expect(stateOfOutcome("changes_required")).toBe("new_version_asked");
    expect(stateOfOutcome("deferred")).toBeNull();
  });
});
```

In `src/lib/client-lane/versionLabels.test.ts` change its `./versionLabels` import to `import { approvalVersionLabels, requestVersionLabels } from "./versionLabels";`, add `import { agencyRequest } from "./testFixtures";` below it, and append:

```ts
describe("requestVersionLabels", () => {
  it("labels each artboard version with its own round, the highest winning", () => {
    const older = agencyRequest({
      id: "rq1",
      approvals: [{ ...agencyRequest().approvals[1], round: 1 }],
    });
    const map = requestVersionLabels([agencyRequest(), older]);
    expect(map.get("g1")).toBe("v1");
    expect(map.get("r1")).toBe("v2");
  });
});
```

`src/services/client-lane.test.ts` is about to hold JSX: rename it first (`/usr/bin/git mv src/services/client-lane.test.ts src/services/client-lane.test.tsx` — bun only parses JSX in `.tsx`). Replace its import block (lines 1-3) with:

```tsx
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook, waitFor } from "@testing-library/react";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { agencyRequest, requestPreview } from "@/lib/client-lane/testFixtures";
import axiosInstance from "@/services/axios";

import {
  approvalApiError,
  createApprovalRequest,
  previewApprovalRequest,
  useApprovalVersionLabels,
} from "./client-lane";
```

and append after the existing `describe`:

```tsx
function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

describe("approval requests (KV)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("previews the file's eligible artboards with no phase filter", async () => {
    const get = vi
      .spyOn(axiosInstance, "get")
      .mockResolvedValue({ data: { data: requestPreview() } } as never);
    const preview = await previewApprovalRequest("f1");
    expect(get).toHaveBeenCalledWith("v1/approval-requests/preview", {
      params: { subject_type: "kv_file", subject_id: "f1" },
    });
    expect(preview.total).toBe(3);
  });

  it("creates a request for the file with the form's body", async () => {
    const post = vi.spyOn(axiosInstance, "post").mockResolvedValue({
      data: {
        data: {
          request: agencyRequest(),
          share_url: "https://frndos.test/s/req_tok",
          approvers: [],
        },
      },
    } as never);
    await createApprovalRequest("f1", {
      kv_phases: ["craft"],
      approver_emails: [],
    });
    expect(post).toHaveBeenCalledWith("v1/approval-requests", {
      subject_type: "kv_file",
      subject_id: "f1",
      kv_phases: ["craft"],
      approver_emails: [],
    });
  });

  it("labels a KV file's client pins from its requests, not v1/approvals", async () => {
    const get = vi
      .spyOn(axiosInstance, "get")
      .mockImplementation((async (url: string) => {
        if (url === "v1/approval-requests")
          return { data: { data: [agencyRequest()] } };
        throw new Error(`unexpected GET ${url}`);
      }) as never);
    const { result } = renderHook(
      () => useApprovalVersionLabels("kv_file", "f1"),
      { wrapper: Wrapper }
    );
    await waitFor(() => expect(result.current.get("r1")).toBe("v2"));
    expect(get.mock.calls.some((c) => c[0] === "v1/approvals")).toBe(false);
  });
});
```

- [ ] **Step 6: Run them to watch them fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/requests.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/statusTone.test.ts
```

Expected: FAIL — `Cannot find module './requests'` / `'./statusTone'`.

- [ ] **Step 7: Write the helpers**

Create `src/lib/client-lane/statusTone.ts`:

```ts
/**
 * The ONE status → pill map of the client lane (spec 2026-10-01 §11.2). The
 * share dialog's request rows, the status block, the client page's artboard
 * cards — and Part B's chips and popover — all read it, so a status never
 * means two colours. Variants are the frndOS v1 `Label`'s; the label text
 * reuses `format.ts` where a word already exists.
 */
import type { LabelVariant } from "@/components/frndos/Label";

import { OUTCOME_LABEL, STATUS_LABEL } from "./format";
import type { ApprovalStatus, DecisionOutcome } from "./types";

export interface Tone {
  variant: LabelVariant;
  label: string;
}

export const STATUS_TONE: Record<ApprovalStatus, Tone> = {
  pending: { variant: "alert", label: STATUS_LABEL.pending },
  approved: { variant: "success", label: STATUS_LABEL.approved },
  approved_with_changes: {
    variant: "success",
    label: STATUS_LABEL.approved_with_changes,
  },
  changes_required: { variant: "error", label: STATUS_LABEL.changes_required },
  not_relevant: { variant: "neutral", label: STATUS_LABEL.not_relevant },
};

/** A person's answer (`null` = not answered yet → "Waiting"). */
export const OUTCOME_TONE: Record<DecisionOutcome, Tone> = {
  approved: { variant: "success", label: OUTCOME_LABEL.approved },
  approved_with_changes: {
    variant: "success",
    label: OUTCOME_LABEL.approved_with_changes,
  },
  changes_required: { variant: "error", label: OUTCOME_LABEL.changes_required },
  deferred: { variant: "alert", label: OUTCOME_LABEL.deferred },
};

export const WAITING_TONE: Tone = { variant: "alert", label: "Waiting" };

/** What an artboard card on the client page says (spec §5.1). */
export type ArtboardState =
  | "undecided"
  | "approved"
  | "approved_with_fixes"
  | "new_version_asked"
  | "replaced"
  | "withdrawn";

export const ARTBOARD_STATE_TONE: Record<ArtboardState, Tone> = {
  undecided: { variant: "neutral", label: "No decision yet" },
  approved: { variant: "success", label: "Approved" },
  approved_with_fixes: { variant: "success", label: "Approved with fixes" },
  new_version_asked: { variant: "error", label: "New version asked" },
  replaced: { variant: "neutral", label: "Replaced by a newer version" },
  withdrawn: { variant: "neutral", label: "Withdrawn" },
};

/** An approval's settled state. `replaced` wins: a superseded approval is
 *  `not_relevant` on the wire, but the client must read "replaced". */
export function artboardStateOf(
  status: ApprovalStatus,
  replaced: boolean
): ArtboardState {
  if (replaced) return "replaced";
  switch (status) {
    case "pending":
      return "undecided";
    case "approved":
      return "approved";
    case "approved_with_changes":
      return "approved_with_fixes";
    case "changes_required":
      return "new_version_asked";
    case "not_relevant":
      return "withdrawn";
  }
}

/** A viewer's own answer as a card state; a deferral is request-level. */
export function stateOfOutcome(outcome: DecisionOutcome): ArtboardState | null {
  if (outcome === "approved") return "approved";
  if (outcome === "approved_with_changes") return "approved_with_fixes";
  if (outcome === "changes_required") return "new_version_asked";
  return null;
}
```

Create `src/lib/client-lane/requests.ts`:

```ts
/**
 * Pure helpers over KV approval requests (spec 2026-10-01): which link is a
 * request link, and the strings the share dialog's request rows read. No
 * React, no api — type-only imports from the service.
 */
import type {
  AgencyRequest,
  ApprovalRequestPreviewItem,
  CreateApprovalRequestInput,
} from "@/services/client-lane";
import type { KvSharePhase } from "@/types/kv/share-link";

import { deferralDate } from "./format";
import type {
  PublicRequest,
  PublicRequestApproval,
  ShareLinkData,
} from "./types";

export interface RequestView {
  request: PublicRequest;
  approvals: PublicRequestApproval[];
}

/**
 * The request a link was sent for, or `null` — deck, plan, KV view and KV
 * round links, and an api that predates requests. KV only (spec D-2): a
 * deck or plan never renders the request page, whatever it carries.
 */
export function requestOf(data: ShareLinkData): RequestView | null {
  if (data.type !== "kv_file" || !data.request) return null;
  return {
    request: data.request,
    approvals: Array.isArray(data.approvals) ? data.approvals : [],
  };
}

export function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

/** Artboards still in the request (a superseded one moved to a newer one). */
export function requestArtboardTotal(
  r: Pick<AgencyRequest, "approvals">
): number {
  return r.approvals.filter((a) => a.superseded_by_request_number === null)
    .length;
}

/** "Request 2 · 1 artboard". */
export function requestTitle(
  r: Pick<AgencyRequest, "number" | "approvals">
): string {
  return `Request ${r.number} · ${plural(requestArtboardTotal(r), "artboard")}`;
}

/**
 * The row's one line (spec §5.2): who an open request waits on and by when;
 * a closed one's result ("Approved · 6/6", "Changes · 5/6").
 */
export function requestRowDescription(r: AgencyRequest): string {
  if (r.status === "not_relevant") return "Withdrawn";
  const total = requestArtboardTotal(r);
  const approved = r.counts.approved + r.counts.approved_with_changes;
  if (r.status !== "pending") {
    const verdict = r.status === "changes_required" ? "Changes" : "Approved";
    return `${verdict} · ${approved}/${total}`;
  }
  const waiting = r.approvers
    .filter((a) => !a.decided)
    .map((a) => a.name || a.email);
  const parts = [
    waiting.length > 0
      ? `Waiting on ${waiting.join(", ")}`
      : `${total - r.counts.pending}/${total} decided`,
  ];
  if (r.deferred_until) {
    parts.push(`More time until ${deferralDate(r.deferred_until)}`);
  } else if (r.decide_by) {
    parts.push(`Decide by ${deferralDate(r.decide_by)}`);
  }
  return parts.join(" · ");
}

/** "TikTok 9:16 — replaces v1, still waiting" (spec §5.2), or null. */
export function replacesNote(item: ApprovalRequestPreviewItem): string | null {
  if (!item.replaces) return null;
  return `${item.label} — replaces v${item.replaces.round}, still waiting`;
}

/** Local `YYYY-MM-DD`, `n` days from today (noon, so DST never shifts it). */
export function isoDayFromToday(n: number): string {
  const d = new Date();
  d.setHours(12, 0, 0, 0);
  d.setDate(d.getDate() + n);
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${day}`;
}

/** `POST v1/approval-requests` body — optional fields omitted, not empty. */
export function buildRequestPayload(input: {
  phases: KvSharePhase[];
  emails: string[];
  message: string;
  decideBy: string;
}): CreateApprovalRequestInput {
  const message = input.message.trim();
  return {
    kv_phases: [...input.phases],
    approver_emails: [...input.emails],
    ...(message ? { message } : {}),
    ...(input.decideBy ? { decide_by: input.decideBy } : {}),
  };
}
```

Append to `src/lib/client-lane/versionLabels.ts` (add `AgencyRequest` to its type import):

```ts

/**
 * version id → "v{round}" across every request's artboards (KV, spec
 * 2026-10-01): an approval's round is its artboard's own, and a version
 * re-sent in a later round keeps the highest.
 */
export function requestVersionLabels(
  requests: Pick<AgencyRequest, "approvals">[]
): Map<string, string> {
  const best = new Map<string, number>();
  for (const request of requests) {
    for (const a of request.approvals) {
      best.set(a.version_id, Math.max(best.get(a.version_id) ?? 0, a.round));
    }
  }
  return new Map([...best].map(([id, round]) => [id, `v${round}`]));
}
```

- [ ] **Step 8: Run every touched suite**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/requests.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/statusTone.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/versionLabels.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/services/client-lane.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.test.tsx
```

Expected: all PASS (DecisionPage unchanged — the optional keys break nothing).

- [ ] **Step 9: Mutation checks**

1. In `requestOf`, drop `data.type !== "kv_file" ||` → "never treats a deck or plan link as a request" FAILS. Restore.
2. In `artboardStateOf`, move `if (replaced) return "replaced";` below the switch → "reads 'replaced' before the status…" FAILS. Restore.
3. In `requestArtboardTotal`, return `r.approvals.length` (no superseded filter) → "titles a request by its live artboards" FAILS ("2 artboards" instead of "1 artboard"). Restore.
4. In `buildRequestPayload`, send `decide_by: input.decideBy` unconditionally → "builds the POST body" FAILS. Restore.
5. In `useApprovalVersionLabels`, pass `{ enabled }` to `useApprovals` → "labels a KV file's client pins from its requests, not v1/approvals" FAILS (the stub throws on `v1/approvals`, the GET is recorded). Restore.

- [ ] **Step 10: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/client-lane/types.ts src/lib/client-lane/publicApi.ts src/lib/client-lane/storage.ts src/lib/client-lane/requests.ts src/lib/client-lane/requests.test.ts src/lib/client-lane/statusTone.ts src/lib/client-lane/statusTone.test.ts src/lib/client-lane/versionLabels.ts src/lib/client-lane/versionLabels.test.ts src/lib/client-lane/testFixtures.ts src/services/client-lane.ts src/services/client-lane.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "src/lib/client-lane/|src/services/client-lane"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: eslint clean, the first grep prints nothing, the count is 895.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add -A src/lib/client-lane src/services && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): client lane wire types, services and helpers for KV approval requests

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: v2 FilterChips — optional multi-select

The request form's phase pills are multi-select with counts (spec §11.2: extend `FilterChips`, never a local pill). `FilterChips` already shows counts; it is single-select only. Add a multi-select mode without changing a single existing caller.

**Files:**
- Modify: `src/components/frndos/v2/FilterChips.tsx`, `src/components/frndos/stories/FilterChipsV2.stories.tsx`, `.agents/skills/frndos-components-v2/SKILL.md` (FilterChips row, line 91)
- Create: `src/components/frndos/v2/FilterChips.test.tsx`

**Interfaces:**
- Produces: `FilterChipsProps<T> = SingleSelect | MultiSelect` where single = `{ selection?: "single"; value: T; onChange(next: T) }` (unchanged for every caller) and multi = `{ selection: "multiple"; values: readonly T[]; onToggle(value: T) }`; shared `{ options; ariaLabel; nowrap?; className? }`.

- [ ] **Step 1: Write the failing test**

Create `src/components/frndos/v2/FilterChips.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { fireEvent, render, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { FilterChips } from "./FilterChips";

const body = () => within(document.body);
const OPTIONS = [
  { value: "craft", label: "Craft", count: 1 },
  { value: "resize", label: "Resize", count: 5 },
  { value: "motion", label: "Motion", count: 2 },
] as const;

describe("FilterChips", () => {
  it("stays single-select by default", () => {
    const onChange = vi.fn();
    render(
      <FilterChips
        ariaLabel="Status"
        options={OPTIONS}
        value="craft"
        onChange={onChange}
      />
    );
    expect(body().getByRole("button", { name: /^Craft/ })).toHaveAttribute(
      "aria-pressed",
      "true"
    );
    fireEvent.click(body().getByRole("button", { name: /^Resize/ }));
    expect(onChange).toHaveBeenCalledWith("resize");
  });

  it("presses every selected chip and toggles one at a time in multiple mode", () => {
    const onToggle = vi.fn();
    render(
      <FilterChips
        selection="multiple"
        ariaLabel="Phases to send"
        options={OPTIONS}
        values={["craft", "motion"]}
        onToggle={onToggle}
      />
    );
    const group = body().getByRole("group", { name: "Phases to send" });
    const pressed = within(group)
      .getAllByRole("button")
      .filter((b) => b.getAttribute("aria-pressed") === "true")
      .map((b) => b.textContent);
    expect(pressed).toEqual(["Craft1", "Motion2"]);

    fireEvent.click(body().getByRole("button", { name: /^Motion/ }));
    expect(onToggle).toHaveBeenCalledWith("motion");
  });
});
```

- [ ] **Step 2: Run it to watch it fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/frndos/v2/FilterChips.test.tsx
```

Expected: the second test FAILS (TS ignores the extra props at runtime; no chip is pressed for `values`, `onToggle` never fires).

- [ ] **Step 3: Implement**

Replace `FilterChipsProps` and the component signature/body head in `src/components/frndos/v2/FilterChips.tsx` (lines 16-56):

```tsx
interface FilterChipsBaseProps<T extends string> {
  options: readonly FilterChipOption<T>[];
  /** Names the group for screen readers ("Filter by status"). */
  ariaLabel: string;
  /**
   * Keep one line on phones too (the caller scrolls it sideways, as
   * `PageHeader`'s chips row does). Default false: the row wraps.
   */
  nowrap?: boolean;
  className?: string;
}

/** The toolbar scope: exactly one chip is on. */
interface FilterChipsSingleProps<T extends string>
  extends FilterChipsBaseProps<T> {
  selection?: "single";
  value: T;
  onChange: (next: T) => void;
}

/**
 * A multi-value scope — the request form's phases ("Craft 1 · Resize 5"):
 * any number of chips are on, and a click toggles one.
 */
interface FilterChipsMultipleProps<T extends string>
  extends FilterChipsBaseProps<T> {
  selection: "multiple";
  values: readonly T[];
  onToggle: (value: T) => void;
}

export type FilterChipsProps<T extends string = string> =
  | FilterChipsSingleProps<T>
  | FilterChipsMultipleProps<T>;
```

Keep the doc comment, then:

```tsx
export function FilterChips<T extends string = string>(
  props: FilterChipsProps<T>
) {
  const { options, ariaLabel, nowrap = false, className } = props;
  const isOn = (value: T) =>
    props.selection === "multiple"
      ? props.values.includes(value)
      : value === props.value;
  const pick = (value: T) =>
    props.selection === "multiple"
      ? props.onToggle(value)
      : props.onChange(value);

  return (
    <div
      role="group"
      aria-label={ariaLabel}
      className={clsx(
        "flex items-center gap-1",
        !nowrap && "max-md:flex-wrap max-md:gap-y-1",
        className
      )}
    >
      {options.map((option) => {
        const active = isOn(option.value);
        return (
          <button
            key={option.value}
            type="button"
            aria-pressed={active}
            onClick={() => pick(option.value)}
```

(the rest of the button — className, icon, label, count — is unchanged). Add one sentence to the doc comment: "`selection="multiple"` turns it into a multi-value scope (`values` + `onToggle`) — the request form's phase pills."

- [ ] **Step 4: Story + skill row**

Append to `src/components/frndos/stories/FilterChipsV2.stories.tsx`:

```tsx
function MultipleControlled() {
  const [values, setValues] = useState<string[]>(["craft", "resize"]);
  return (
    <FilterChips
      selection="multiple"
      ariaLabel="Phases to send"
      values={values}
      onToggle={(v) =>
        setValues((prev) =>
          prev.includes(v) ? prev.filter((x) => x !== v) : [...prev, v]
        )
      }
      options={[
        { value: "craft", label: "Craft", count: 1 },
        { value: "resize", label: "Resize", count: 5 },
        { value: "motion", label: "Motion", count: 2 },
      ]}
    />
  );
}

export const MultiSelect: Story = { render: () => <MultipleControlled /> };
```

and change the meta's component description to end "…Single-select by default; `selection="multiple"` (`values` / `onToggle`) for a multi-value scope. `aria-pressed` per chip; wraps on phones."

In `.agents/skills/frndos-components-v2/SKILL.md` line 91 replace the description cell with:

`Toolbar scope chips (look = Audience `RelationshipFilterChips`): `options[{value,label,count?,icon?}]`, `ariaLabel`; single-select `value`/`onChange` (default) or `selection="multiple"` + `values`/`onToggle` (Client Lane request form's phase pills). Active = solid fill; wraps on phones.`

- [ ] **Step 5: Run the test + the toolbar regression**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/frndos/v2/FilterChips.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/frndos/v2/PageToolbar.test.tsx
```

Expected: PASS, and PageToolbar's count unchanged from Task 0.

- [ ] **Step 6: Mutation check**

In `isOn`, return `value === (props as { value?: T }).value` for both modes → "presses every selected chip…" FAILS. Restore.

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/frndos/v2/FilterChips.tsx src/components/frndos/v2/FilterChips.test.tsx src/components/frndos/stories/FilterChipsV2.stories.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "FilterChips|PageHeader|PageToolbar"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: no grep output; 895.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/frndos/v2/FilterChips.tsx src/components/frndos/v2/FilterChips.test.tsx src/components/frndos/stories/FilterChipsV2.stories.tsx .agents/skills/frndos-components-v2/SKILL.md && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): v2 FilterChips gains a multi-select mode

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Shared agency pieces — Label pills, avatar, decision rows, approver emails, send step

Lift what the request rows and the request form reuse out of `ApprovalStatusBlock` and `RequestApprovalPanel` (spec §5.2 "reuses the redesigned ApprovalStatusBlock building blocks"), move the hand-rolled status pill to the frndOS `Label` (spec §11.1), and keep deck / plan behaving exactly as before.

**Files:**
- Create: `src/components/client-lane/StatusPill.tsx`, `src/components/client-lane/agency/PersonAvatar.tsx`, `src/components/client-lane/agency/DecisionRow.tsx`, `src/components/client-lane/agency/useApproverEmails.ts`, `src/components/client-lane/agency/RequestApprovalPanel.test.tsx`
- Modify: `src/lib/client-lane/statusTone.ts` (add `DECIDED_TONE`), `src/components/client-lane/agency/ApprovalStatusBlock.tsx`, `src/components/client-lane/agency/ApprovalStatusBlock.test.tsx`, `src/components/client-lane/agency/RequestApprovalPanel.tsx`, `src/components/studio/kv-generator/KvSharePanel.tsx` (lines 690-698 only — the send step call)

**Interfaces:**
- Consumes: `STATUS_TONE`, `OUTCOME_TONE`, `WAITING_TONE`, `ARTBOARD_STATE_TONE`, `ArtboardState` (Task 1).
- Produces:
  - `StatusPill({ status: ApprovalStatus; suffix?: string; className?: string })`, `OutcomePill({ outcome: DecisionOutcome | null })`, `ApproverPill({ decided: boolean })`, `ArtboardStatePill({ state: ArtboardState })` — the only importer of v1 `Label`.
  - `PersonAvatar({ name: string })` — the only importer of v1 `Avatar` in client-lane agency.
  - `DecisionRow({ decision: ApprovalDecision })`, `DecisionList({ decisions: ApprovalDecision[]; labelledBy?: string })` (latest per person + "Show n earlier answers" fold; renders nothing for `[]`).
  - `useApproverEmails(brandId?: string | null)` → `ApproverEmails = { emails; draft; setDraft; error; setError; add(raw): boolean; remove(email); pop(); suggestions: ApproverSuggestion[]; commit(): string[] | null }`; `APPROVER_EMAIL`, `MAX_APPROVERS`.
  - `SendStepResult { share_url; message: string | null; number: number; approvers: CreateApprovalResponse["approvers"] }`, `sendStepResultOfRound(created: CreateApprovalResponse): SendStepResult`, `ApprovalSendStep({ result: SendStepResult; title; subjectType; headline?: string; onDone })`.

- [ ] **Step 1: Write the failing tests**

Append to `src/components/client-lane/agency/ApprovalStatusBlock.test.tsx` inside `describe("ApprovalStatusBlock", …)`:

```tsx
  it("draws its pills with the frndOS Label, not hand-rolled 9px text", async () => {
    stubApprovals([
      round({
        status: "pending",
        policy: "required",
        approvers: [{ name: "piliw94875", decided: false }],
        decisions: [],
      }),
    ]);
    const { container } = renderBlock();

    const approvers = await body().findByRole("list", { name: "Approvers" });
    // Label `alert`, dark — the shared statusTone map.
    expect(within(approvers).getByText("Waiting").className).toContain(
      "bg-yellow-400"
    );
    expect(body().getByText("Pending").className).toContain("bg-yellow-400");
    expect(container.innerHTML).not.toMatch(/text-\[9px\]|px-\[7px\]/);
  });
```

Create `src/components/client-lane/agency/RequestApprovalPanel.test.tsx` (deck / plan regression — this panel had no suite):

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { pendingApproval } from "@/lib/client-lane/testFixtures";
import type { ShareSubjectType } from "@/lib/client-lane/types";
import axiosInstance from "@/services/axios";
import { useToastStore } from "@/store/useToast";

import { RequestApprovalPanel } from "./RequestApprovalPanel";

const body = () => within(document.body);

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

/** `POST v1/approvals` spied, never vi.mock'ed. */
function stubCreate() {
  return vi.spyOn(axiosInstance, "post").mockResolvedValue({
    data: {
      data: {
        approval: {
          ...pendingApproval({ round: 3, message: "Smaller logo" }),
          subject_type: "deck",
          subject_id: "d1",
          share_link_id: "l1",
        },
        share_url: "https://frndos.test/s/deck_tok",
        approvers: [
          {
            email: "dina@brand.co.id",
            name: "Dina",
            user_id: "u9",
            personal_url: "https://frndos.test/s/deck_tok?k=lanecode",
            mail_sent: true,
          },
        ],
      },
    },
  } as never);
}

function renderPanel(subjectType: ShareSubjectType = "deck") {
  return render(
    <RequestApprovalPanel
      subjectType={subjectType}
      subjectId="d1"
      title="Q4 deck"
      onDone={() => {}}
      onCancel={() => {}}
    />,
    { wrapper: Wrapper }
  );
}

beforeEach(() => {
  vi.restoreAllMocks();
  useToastStore.getState().clearToasts();
});

describe("RequestApprovalPanel — deck and plan, unchanged", () => {
  it("requests a deck round, then shows its send step", async () => {
    const post = stubCreate();
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const user = userEvent.setup();
    renderPanel();

    await user.type(
      body().getByLabelText("Approver email"),
      "Dina@Brand.co.id{Enter}"
    );
    expect(body().getByText("dina@brand.co.id")).toBeInTheDocument();
    await user.type(body().getByLabelText("What changed"), "Smaller logo");
    await user.click(body().getByRole("button", { name: "Create link" }));

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith("v1/approvals", {
        subject_type: "deck",
        subject_id: "d1",
        approver_emails: ["dina@brand.co.id"],
        message: "Smaller logo",
      })
    );
    expect(
      await body().findByText("v3 is out for approval")
    ).toBeInTheDocument();
    expect(body().getByText("personal link sent")).toBeInTheDocument();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_requested",
      expect.objectContaining({
        subject_type: "deck",
        round: 3,
        entry: "request_button",
        phases: [],
      })
    );
  });

  it("commits an email typed but never entered", async () => {
    const post = stubCreate();
    const user = userEvent.setup();
    renderPanel();

    await user.type(body().getByLabelText("Approver email"), "bayu@brand.co.id");
    await user.click(body().getByRole("button", { name: "Create link" }));

    await waitFor(() =>
      expect(post.mock.calls[0][1]).toMatchObject({
        approver_emails: ["bayu@brand.co.id"],
      })
    );
  });

  it("keeps a plan's send step free of a version label", async () => {
    stubCreate();
    const user = userEvent.setup();
    renderPanel("campaign");

    await user.click(body().getByRole("button", { name: "Create link" }));
    expect(
      await body().findByText("This round is out for approval")
    ).toBeInTheDocument();
  });

  it("explains an existing member on the field, not in a toast", async () => {
    vi.spyOn(axiosInstance, "post").mockRejectedValue({
      response: {
        status: 422,
        data: { code: "already_a_member", email: "dina@brand.co.id" },
      },
    });
    const user = userEvent.setup();
    renderPanel();

    await user.type(
      body().getByLabelText("Approver email"),
      "dina@brand.co.id{Enter}"
    );
    await user.click(body().getByRole("button", { name: "Create link" }));

    expect(
      await body().findByText(/dina@brand.co.id is already a member/)
    ).toBeInTheDocument();
    expect(useToastStore.getState().toasts).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run them to watch them fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/ApprovalStatusBlock.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/RequestApprovalPanel.test.tsx
```

Expected: the Label test FAILS (no `bg-yellow-400`; `text-[9px]` present). The RequestApprovalPanel suite PASSES at HEAD — it is the regression net the refactor must keep green (if it fails, fix the test against HEAD behaviour before touching code).

- [ ] **Step 3: The pill, avatar and decision-row files**

Add to `src/lib/client-lane/statusTone.ts` after `WAITING_TONE`:

```ts
export const DECIDED_TONE: Tone = { variant: "success", label: "Decided" };
```

Create `src/components/client-lane/StatusPill.tsx`:

```tsx
"use client";

import clsx from "clsx";

import { Label } from "@/components/frndos/Label";
import {
  ARTBOARD_STATE_TONE,
  DECIDED_TONE,
  OUTCOME_TONE,
  STATUS_TONE,
  WAITING_TONE,
  type ArtboardState,
  type Tone,
} from "@/lib/client-lane/statusTone";
import type { ApprovalStatus, DecisionOutcome } from "@/lib/client-lane/types";

/**
 * Every client-lane status pill is the frndOS v1 `Label` (spec 2026-10-01
 * §11.2), toned by the one `statusTone` map. This is the ONLY client-lane
 * file that imports `Label`, so v2 files (the request rows, the client
 * page) show a pill without mixing v1 and v2 in one file.
 */
function Pill({
  tone,
  suffix,
  className,
}: {
  tone: Tone;
  suffix?: string;
  className?: string;
}) {
  return (
    <Label
      size="small"
      variant={tone.variant}
      dark
      className={clsx("shrink-0 whitespace-nowrap", className)}
    >
      {tone.label}
      {suffix ?? ""}
    </Label>
  );
}

export function StatusPill({
  status,
  suffix,
  className,
}: {
  status: ApprovalStatus;
  suffix?: string;
  className?: string;
}) {
  return (
    <Pill tone={STATUS_TONE[status]} suffix={suffix} className={className} />
  );
}

/** A person's answer; `null` = not answered yet ("Waiting"). */
export function OutcomePill({ outcome }: { outcome: DecisionOutcome | null }) {
  return <Pill tone={outcome ? OUTCOME_TONE[outcome] : WAITING_TONE} />;
}

/** A named approver on a request: decided or waiting (no outcome on the wire). */
export function ApproverPill({ decided }: { decided: boolean }) {
  return <Pill tone={decided ? DECIDED_TONE : WAITING_TONE} />;
}

/** An artboard card's state on the client page. */
export function ArtboardStatePill({ state }: { state: ArtboardState }) {
  return <Pill tone={ARTBOARD_STATE_TONE[state]} />;
}
```

Create `src/components/client-lane/agency/PersonAvatar.tsx`:

```tsx
"use client";

import { Avatar } from "@/components/frndos/Avatar";
import { getAvatarColor, getInitials } from "@/lib/getInitials";

/** A person's face in the share sheets — the frndOS v1 `Avatar`, alone in
 *  its file so v2 rows can use it without importing v1. */
export function PersonAvatar({ name }: { name: string }) {
  return (
    <Avatar
      size="2xs"
      initials={getInitials(name)}
      bgColor={getAvatarColor(name)}
      className="mt-px"
      aria-hidden
    />
  );
}
```

Create `src/components/client-lane/agency/DecisionRow.tsx` (lifted from `ApprovalStatusBlock.tsx` lines 69-111 and 289-320; the two `text-[11px]` become `text-textXs`):

```tsx
"use client";

import { CaretDown } from "@phosphor-icons/react";
import clsx from "clsx";
import { useState } from "react";

import {
  latestPerActor,
  supersededDecisions,
} from "@/lib/client-lane/decisions";
import {
  OUTCOME_LABEL,
  deferralDate,
  shortWhen,
} from "@/lib/client-lane/format";
import type { ApprovalDecision } from "@/lib/client-lane/types";

import { PersonAvatar } from "./PersonAvatar";

/** One answer: who, what, when — then advisory / pins / note underneath. */
export function DecisionRow({ decision }: { decision: ApprovalDecision }) {
  const meta = [
    decision.advisory ? "Advisory · doesn't close the round" : null,
    decision.pins.length > 0
      ? `${decision.pins.length} ${decision.pins.length === 1 ? "pin" : "pins"}`
      : null,
    decision.outcome === "deferred" && decision.deferred_until
      ? `Until ${deferralDate(decision.deferred_until)}`
      : null,
  ].filter(Boolean);
  return (
    <li className="flex items-start gap-2.5">
      <PersonAvatar name={decision.actor} />
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2 text-textXs">
          <span className="min-w-0 truncate">
            <span className="text-text-inverse">{decision.actor}</span>
            <span className="text-text-inverse-subtle">
              {" · "}
              {OUTCOME_LABEL[decision.outcome]}
            </span>
          </span>
          {decision.decided_at ? (
            <span className="shrink-0 text-text-inverse-subtlest">
              {shortWhen(decision.decided_at)}
            </span>
          ) : null}
        </div>
        {meta.length > 0 ? (
          <p className="mt-0.5 text-textXs text-text-inverse-subtlest">
            {meta.join(" · ")}
          </p>
        ) : null}
        {decision.note ? (
          <p className="mt-1 line-clamp-2 text-textXs text-text-inverse-subtle">
            &ldquo;{decision.note}&rdquo;
          </p>
        ) : null}
      </div>
    </li>
  );
}

/**
 * One row per person — their latest answer — and every answer they replaced
 * folded under "Show n earlier answers". Nothing for no decisions.
 */
export function DecisionList({
  decisions,
  labelledBy,
}: {
  decisions: ApprovalDecision[];
  /** The id of the visible heading that names the list. */
  labelledBy?: string;
}) {
  const [showEarlier, setShowEarlier] = useState(false);
  const latest = latestPerActor(decisions);
  const earlier = supersededDecisions(decisions);
  if (latest.length === 0) return null;

  return (
    <>
      <ul aria-labelledby={labelledBy} className="flex flex-col gap-3">
        {latest.map((d) => (
          <DecisionRow key={d.id} decision={d} />
        ))}
      </ul>
      {earlier.length > 0 && (
        <>
          <button
            type="button"
            aria-expanded={showEarlier}
            onClick={() => setShowEarlier((v) => !v)}
            className="flex w-fit items-center gap-1 rounded-md font-geist text-textXs text-text-inverse-subtle outline-none transition-all duration-200 ease-out hover:text-text-inverse focus-visible:ring-2 focus-visible:ring-white/40"
          >
            <CaretDown
              size={12}
              aria-hidden
              className={clsx(
                "transition-transform duration-200 ease-out",
                showEarlier && "rotate-180"
              )}
            />
            {showEarlier
              ? "Hide earlier answers"
              : `Show ${earlier.length} earlier ${earlier.length === 1 ? "answer" : "answers"}`}
          </button>
          {showEarlier && (
            <ul
              aria-label="Earlier answers"
              className="flex max-h-48 flex-col gap-3 overflow-y-auto border-l border-white/5 pl-3 opacity-80"
            >
              {earlier.map((d) => (
                <DecisionRow key={d.id} decision={d} />
              ))}
            </ul>
          )}
        </>
      )}
    </>
  );
}
```

- [ ] **Step 4: ApprovalStatusBlock reads them**

In `src/components/client-lane/agency/ApprovalStatusBlock.tsx`:
- Imports: drop `CaretDown`, `clsx`, `Avatar`, `getAvatarColor`/`getInitials`, `supersededDecisions`, `OUTCOME_LABEL`, `STATUS_LABEL`, `shortWhen` if unused afterwards (keep `shortWhen` — the footer uses it — and `deferralDate`); drop the `ApprovalDecision` type import. Add:

```tsx
import { OutcomePill, StatusPill } from "../StatusPill";
import { DecisionList } from "./DecisionRow";
import { PersonAvatar } from "./PersonAvatar";
```

- Delete `STATUS_PILL`, `PILL` (lines 41-51), the local `PersonAvatar` and `DecisionRow` (lines 57-111), the `showEarlier` state (line 141) and `const earlier = …` (line 151).
- The header pill (lines 194-205) becomes:

```tsx
        <StatusPill
          status={current.status}
          className="mt-0.5"
          suffix={
            current.deferred_until
              ? ` · until ${deferralDate(current.deferred_until)}`
              : undefined
          }
        />
```

- The approver pill (lines 226-237) becomes `<OutcomePill outcome={a.decided && a.outcome ? a.outcome : null} />`.
- The responses block (lines 276-322) becomes:

```tsx
      {latest.length > 0 && (
        <div className="mt-4 flex flex-col gap-2">
          <p className={EYEBROW} id={`responses-${current.id}`}>
            Responses
          </p>
          <DecisionList
            decisions={current.decisions}
            labelledBy={`responses-${current.id}`}
          />
        </div>
      )}
```

- [ ] **Step 5: The approver-email hook and the send step**

Create `src/components/client-lane/agency/useApproverEmails.ts` (logic moved verbatim from `useApprovalRequestForm`, lines 203-276):

```ts
"use client";

import { useMemo, useState } from "react";

import { useBrandMembers } from "@/hooks/useBrandRoles";

export const APPROVER_EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const MAX_APPROVERS = 10;

export interface ApproverSuggestion {
  id: string;
  name: string | null;
  email: string | null;
}

/** The `brand_members` row of `GET v1/brands/{brand}/members`, as far as the picker reads it. */
interface BrandMemberRow extends ApproverSuggestion {
  brand_role?: { id: string; name: string | null } | null;
}

/**
 * The approver emails of a request form — committed on Enter / comma /
 * space / blur, validated, capped — plus the brand's existing clients as
 * one-tap suggestions. Shared by the deck / plan request panel and the KV
 * request form so both validate the same way.
 */
export function useApproverEmails(brandId?: string | null) {
  const [emails, setEmails] = useState<string[]>([]);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);

  // Existing clients of the brand (the locked `client` role). The members
  // endpoint carries no `scope`, so the role name is the discriminator.
  const members = useBrandMembers(brandId ?? "");
  const suggestions = useMemo<ApproverSuggestion[]>(() => {
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

  const normalise = (raw: string) => raw.trim().toLowerCase().replace(/,$/, "");

  const add = (raw: string): boolean => {
    const value = normalise(raw);
    if (!value) return false;
    if (!APPROVER_EMAIL.test(value)) {
      setError("That doesn't look like an email address.");
      return false;
    }
    if (emails.includes(value)) {
      setDraft("");
      return true;
    }
    if (emails.length >= MAX_APPROVERS) {
      setError(`Up to ${MAX_APPROVERS} approvers per round.`);
      return false;
    }
    setEmails((prev) => [...prev, value]);
    setDraft("");
    setError(null);
    return true;
  };

  /**
   * The list a submit sends. A draft typed and submitted in one motion (no
   * blur, no Enter) is committed here and returned directly — the state
   * update would not land before the submit reads it. `null` when that draft
   * is invalid (the error is set).
   */
  const commit = (): string[] | null => {
    const typed = draft.trim();
    if (!typed) return emails;
    const value = normalise(typed);
    if (!APPROVER_EMAIL.test(value)) {
      setError("That doesn't look like an email address.");
      return null;
    }
    let next = emails;
    if (!next.includes(value)) {
      if (next.length >= MAX_APPROVERS) {
        setError(`Up to ${MAX_APPROVERS} approvers per round.`);
        return null;
      }
      next = [...next, value];
      setEmails(next);
    }
    setDraft("");
    setError(null);
    return next;
  };

  return {
    emails,
    draft,
    setDraft,
    error,
    setError,
    add,
    remove: (email: string) =>
      setEmails((prev) => prev.filter((e) => e !== email)),
    pop: () => setEmails((prev) => prev.slice(0, -1)),
    suggestions,
    commit,
  };
}

export type ApproverEmails = ReturnType<typeof useApproverEmails>;
```

In `src/components/client-lane/agency/RequestApprovalPanel.tsx`:
- Drop `EMAIL`, `MAX_APPROVERS`, `BrandMemberRow` (lines 36-46), the `useMemo` and `useBrandMembers` imports; add `import { useApproverEmails } from "./useApproverEmails";`.
- In `useApprovalRequestForm`, replace the email state, suggestions, `addEmail`, `removeEmail` (lines 203-248) with `const approvers = useApproverEmails(brandId);` and keep `const [message, setMessage] = useState("");`. Replace the draft-commit block in `submit` (lines 258-276) with:

```ts
    const finalEmails = approvers.commit();
    if (finalEmails === null) return;
```

  `already_a_member` now calls `approvers.setError(…)` (same text). The return object becomes:

```ts
  return {
    emails: approvers.emails,
    emailDraft: approvers.draft,
    setEmailDraft: approvers.setDraft,
    emailError: approvers.error,
    setEmailError: approvers.setError,
    addEmail: approvers.add,
    removeEmail: approvers.remove,
    popEmail: approvers.pop,
    suggestions: approvers.suggestions,
    message,
    setMessage,
    kvMissing,
    submit,
    pending: create.isPending,
  };
```

- Replace `ApprovalSendStep`'s props and the three places that read `result.approval` (lines 478-513):

```tsx
/** What the send step needs — from a created round (deck, plan) or a KV request. */
export interface SendStepResult {
  share_url: string;
  message: string | null;
  /** The round (deck, plan) or the request number (KV) — `approval_link_shared.round`. */
  number: number;
  approvers: CreateApprovalResponse["approvers"];
}

export function sendStepResultOfRound(
  created: CreateApprovalResponse
): SendStepResult {
  return {
    share_url: created.share_url,
    message: created.approval.message,
    number: created.approval.round,
    approvers: created.approvers,
  };
}

/**
 * The send step (FR-43 / C-7): Copy · WhatsApp · Email around the OBJECT link,
 * plus one row per named approver saying their personal mail went out.
 */
export function ApprovalSendStep({
  result,
  title,
  subjectType,
  headline,
  onDone,
}: {
  result: SendStepResult;
  title: string;
  subjectType: ShareSubjectType;
  /** Overrides "v{n} is / This round is out for approval" (KV: "Request n is …"). */
  headline?: string;
  onDone: () => void;
}) {
  const showToast = useToastStore((s) => s.showToast);
  const [copied, setCopied] = useState(false);
  // A deck's round lines up with its `v{n}`; a plan round or a KV request
  // number does not, so only decks name a version.
  const versionLabel = subjectType === "deck" ? `v${result.number}` : null;
  const text = sendMessage(result.message, title, versionLabel, result.share_url);

  const shared = (channel: "copy" | "whatsapp" | "email") =>
    trackApprovalLinkShared({
      subject_type: subjectType,
      round: result.number,
      channel,
    });
```

  and the headline span (lines 529-532) becomes:

```tsx
        <span className="text-textSmMedium text-text-inverse">
          {headline ??
            `${versionLabel ? `${versionLabel} is` : "This round is"} out for approval`}
        </span>
```

- In `RequestApprovalPanel` (line 84) pass `result={sendStepResultOfRound(result)}`.

In `src/components/studio/kv-generator/KvSharePanel.tsx` the one call (lines 692-697) passes `result={sendStepResultOfRound(sent)}` and imports `sendStepResultOfRound` beside `ApprovalSendStep` (Task 6 deletes this call; it only has to compile until then).

- [ ] **Step 6: Run the suites**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/ApprovalStatusBlock.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/RequestApprovalPanel.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/brands/campaign-planner/SharePlanDialog.test.tsx
```

Expected: all PASS, counts = Task 0 + the new tests.

- [ ] **Step 7: Mutation checks**

1. In `StatusPill.tsx`'s `Pill`, render `<span className="rounded-full px-[7px] py-px text-[9px]">` instead of `Label` → "draws its pills with the frndOS Label" FAILS. Restore.
2. In `useApproverEmails.commit`, return `emails` without committing the draft (delete the body after `if (!typed) return emails;`, ending `return emails;`) → "commits an email typed but never entered" FAILS. Restore.
3. In `ApprovalSendStep`, make `versionLabel` always `v${result.number}` → "keeps a plan's send step free of a version label" FAILS. Restore.

- [ ] **Step 8: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/client-lane/statusTone.ts src/components/client-lane/StatusPill.tsx src/components/client-lane/agency/PersonAvatar.tsx src/components/client-lane/agency/DecisionRow.tsx src/components/client-lane/agency/useApproverEmails.ts src/components/client-lane/agency/ApprovalStatusBlock.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/components/client-lane/agency/RequestApprovalPanel.tsx src/components/client-lane/agency/RequestApprovalPanel.test.tsx src/components/studio/kv-generator/KvSharePanel.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-lane/|KvSharePanel"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: no grep output; 895.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/client-lane/statusTone.ts src/components/client-lane src/components/studio/kv-generator/KvSharePanel.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
refactor(web): client lane pills on the frndOS Label; shared decision rows, approver emails and send step

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: KvRequestForm — the request form

Spec §5.2 "Request form": phase pills with counts from the preview, `Already approved · n` and `Waiting · n` collapsed (api ruling R2: the same version still pending elsewhere is listed, never re-sent), per-item replaced notes, approver chips, message, optional Decide by, Send → the existing send step. One preview call with no `kv_phases` gives every phase's count; pills narrow it client-side and the POST sends the chosen `kv_phases`.

**Files:**
- Create: `src/components/client-lane/agency/ApproverEmailsField.tsx` (v2), `src/components/client-lane/agency/DecideByField.tsx` (v1 DatePicker only), `src/components/client-lane/agency/KvRequestForm.tsx` (v2), `src/components/client-lane/agency/KvRequestForm.test.tsx`
- Modify: `src/lib/analytics/client-lane-events.ts`

**Interfaces:**
- Consumes: `useApprovalRequestPreview`, `useCreateApprovalRequest`, `approvalApiError`, `approvalRequestsRoot`, `CreateApprovalRequestResponse`, the preview's `waiting` / `already_approved` (both with `phase`) (Task 1); `buildRequestPayload`, `plural`, `replacesNote`, `isoDayFromToday` (Task 1); `useApproverEmails`, `ApprovalSendStep` (Task 3); `FilterChips` multi (Task 2).
- Produces:
  - `KvRequestForm({ fileId: string; fileName: string; brandId?: string | null; onDone(): void; onCancel(): void })`
  - `ApproverEmailsField({ approvers: ApproverEmails; disabled?: boolean })`, `DecideByField({ value: string; onChange(v: string): void; disabled?: boolean })`
  - analytics: `trackApprovalRequestSent({ request_number, artboard_count, phases, approver_count, has_deadline })`, `trackApprovalRequestSendFailed({ reason, http_status })`

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/agency/KvRequestForm.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { agencyRequest, requestPreview } from "@/lib/client-lane/testFixtures";
import axiosInstance from "@/services/axios";
import { useToastStore } from "@/store/useToast";

import { KvRequestForm } from "./KvRequestForm";

const body = () => within(document.body);
const toasts = () => useToastStore.getState().toasts;

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

/** The preview GET and the create POST, spied — never vi.mock'ed. */
function stubApi(preview = requestPreview()) {
  const get = vi
    .spyOn(axiosInstance, "get")
    .mockImplementation((async (url: string) => {
      if (url === "v1/approval-requests/preview")
        return { data: { data: preview } };
      throw new Error(`unexpected GET ${url}`);
    }) as never);
  const post = vi.spyOn(axiosInstance, "post").mockImplementation((async () => ({
    data: {
      data: {
        request: agencyRequest({ number: 3 }),
        share_url: "https://frndos.test/s/req_tok",
        approvers: [],
      },
    },
  })) as never);
  return { get, post };
}

function refuse(
  code: string,
  extra: Record<string, unknown> = {},
  status = 422
) {
  vi.spyOn(axiosInstance, "post").mockRejectedValue({
    response: { status, data: { code, ...extra } },
  });
}

function renderForm() {
  return render(
    <KvRequestForm
      fileId="f1"
      fileName="Ramadan hero"
      onDone={() => {}}
      onCancel={() => {}}
    />,
    { wrapper: Wrapper }
  );
}

beforeEach(() => {
  vi.restoreAllMocks();
  useToastStore.getState().clearToasts();
});

describe("KvRequestForm", () => {
  it("offers every ready phase with its count, all on", async () => {
    stubApi();
    renderForm();

    const group = await body().findByRole("group", { name: "Phases to send" });
    expect(
      within(group)
        .getAllByRole("button")
        .map((b) => [b.textContent, b.getAttribute("aria-pressed")])
    ).toEqual([
      ["Craft1", "true"],
      ["Resize2", "true"],
    ]);
    expect(body().getByText("3 artboards in this request")).toBeInTheDocument();
  });

  it("narrows by phase and sends only the phases left on", async () => {
    const { post } = stubApi();
    const user = userEvent.setup();
    renderForm();

    await user.click(await body().findByRole("button", { name: /^Resize/ }));
    expect(body().getByText("1 artboard in this request")).toBeInTheDocument();
    expect(body().queryByText(/replaces v1/)).toBeNull();
    await user.click(body().getByRole("button", { name: "Send request" }));

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith("v1/approval-requests", {
        subject_type: "kv_file",
        subject_id: "f1",
        kv_phases: ["craft"],
        approver_emails: [],
      })
    );
  });

  it("blocks Send once every phase is off", async () => {
    stubApi();
    const user = userEvent.setup();
    renderForm();

    await user.click(await body().findByRole("button", { name: /^Craft/ }));
    await user.click(body().getByRole("button", { name: /^Resize/ }));
    expect(body().getByText("Pick at least one phase.")).toBeInTheDocument();
    expect(body().getByRole("button", { name: "Send request" })).toBeDisabled();
  });

  it("names what a waiting artboard replaces and folds what is approved", async () => {
    stubApi();
    const user = userEvent.setup();
    renderForm();

    expect(
      await body().findByText(
        "Resize · TikTok · 1080×1920 — replaces v1, still waiting"
      )
    ).toBeInTheDocument();
    const fold = body().getByRole("button", { name: "Already approved · 1" });
    expect(fold).toHaveAttribute("aria-expanded", "false");
    expect(body().queryByText("Motion · 9:16 · 1080×1920")).toBeNull();
    await user.click(fold);
    expect(body().getByText("Motion · 9:16 · 1080×1920")).toBeInTheDocument();
  });

  it("sends approvers and a message, then shows the send step", async () => {
    const { post } = stubApi();
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const user = userEvent.setup();
    renderForm();

    await user.type(
      await body().findByLabelText("Approver email"),
      "dina@brand.co.id{Enter}"
    );
    expect(body().getByText("dina@brand.co.id")).toBeInTheDocument();
    await user.type(body().getByLabelText("Message"), "Smaller logo");
    await user.click(body().getByRole("button", { name: "Send request" }));

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith("v1/approval-requests", {
        subject_type: "kv_file",
        subject_id: "f1",
        kv_phases: ["craft", "resize"],
        approver_emails: ["dina@brand.co.id"],
        message: "Smaller logo",
      })
    );
    expect(
      await body().findByText("Request 3 is out for approval")
    ).toBeInTheDocument();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_sent",
      expect.objectContaining({
        request_number: 3,
        artboard_count: 2,
        phases: ["craft", "resize"],
        approver_count: 1,
        has_deadline: false,
      })
    );
  });

  it("explains nothing_ready and re-reads what is ready", async () => {
    const { get } = stubApi();
    refuse("nothing_ready");
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const user = userEvent.setup();
    renderForm();

    await user.click(
      await body().findByRole("button", { name: "Send request" })
    );

    await waitFor(() => expect(toasts()[0]?.title).toBe("Nothing new to send"));
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_send_failed",
      expect.objectContaining({ reason: "nothing_ready", http_status: 422 })
    );
    await waitFor(() =>
      expect(
        get.mock.calls.filter((c) => c[0] === "v1/approval-requests/preview")
      ).toHaveLength(2)
    );
  });

  it("names the per-request cap on too_many_items", async () => {
    stubApi();
    refuse("too_many_items", { max: 50 });
    const user = userEvent.setup();
    renderForm();

    await user.click(
      await body().findByRole("button", { name: "Send request" })
    );
    await waitFor(() =>
      expect(toasts()[0]?.description).toMatch(/up to 50 artboards/)
    );
  });

  it("folds what waits in another request, narrowed by phase", async () => {
    stubApi();
    const user = userEvent.setup();
    renderForm();

    await user.click(
      await body().findByRole("button", { name: "Waiting · 1" })
    );
    expect(
      body().getByText("Resize · IG Story · 1080×1920 — in Request 1")
    ).toBeInTheDocument();
    await user.click(body().getByRole("button", { name: /^Resize/ }));
    expect(body().queryByRole("button", { name: /^Waiting/ })).toBeNull();
    // Motion is not a sendable phase here, so its approved clip stays listed.
    expect(
      body().getByRole("button", { name: "Already approved · 1" })
    ).toBeInTheDocument();
  });

  it("re-reads the preview and the list when another request won the race", async () => {
    const { get } = stubApi();
    refuse("round_conflict", {}, 409);
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const user = userEvent.setup();
    renderForm();

    await user.click(
      await body().findByRole("button", { name: "Send request" })
    );

    await waitFor(() =>
      expect(toasts()[0]?.title).toBe("Someone else just sent a request")
    );
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_send_failed",
      expect.objectContaining({ reason: "round_conflict", http_status: 409 })
    );
    await waitFor(() =>
      expect(
        get.mock.calls.filter((c) => c[0] === "v1/approval-requests/preview")
      ).toHaveLength(2)
    );
  });

  it("puts an existing member's refusal on the approver field", async () => {
    stubApi();
    refuse("already_a_member", { email: "dina@brand.co.id" });
    const user = userEvent.setup();
    renderForm();

    await user.type(
      await body().findByLabelText("Approver email"),
      "dina@brand.co.id{Enter}"
    );
    await user.click(body().getByRole("button", { name: "Send request" }));
    expect(
      await body().findByText(/dina@brand.co.id is already a member/)
    ).toBeInTheDocument();
    expect(toasts()).toHaveLength(0);
  });

  it("says so when the preview cannot load, and tries again", async () => {
    let calls = 0;
    vi.spyOn(axiosInstance, "get").mockImplementation((async () => {
      calls += 1;
      if (calls === 1) throw { response: { status: 500, data: {} } };
      return { data: { data: requestPreview() } };
    }) as never);
    const user = userEvent.setup();
    renderForm();

    await user.click(await body().findByRole("button", { name: "Try again" }));
    expect(
      await body().findByRole("group", { name: "Phases to send" })
    ).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run it to watch it fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvRequestForm.test.tsx
```

Expected: FAIL — `Cannot find module './KvRequestForm'`.

- [ ] **Step 3: Analytics helpers**

Append to the agency section of `src/lib/analytics/client-lane-events.ts` (after `trackApprovalLinkShared`, line 136):

```ts

/* ── Agency side — KV approval requests (spec 2026-10-01 §5.3) ─────────── */

/** A KV request was sent (`POST v1/approval-requests` succeeded). */
export const trackApprovalRequestSent = (props: {
  request_number: number;
  /** Artboards frozen into the request. */
  artboard_count: number;
  phases: KvSharePhase[];
  approver_count: number;
  has_deadline: boolean;
}) => safeCapture("client_lane.approval_request_sent", props);

export const trackApprovalRequestSendFailed = (props: {
  reason: string;
  http_status: number | null;
}) => safeCapture("client_lane.approval_request_send_failed", props);
```

- [ ] **Step 4: The two field files**

Create `src/components/client-lane/agency/DecideByField.tsx`:

```tsx
"use client";

import DatePicker from "@/components/frndos/DatePicker";
import { isoDayFromToday } from "@/lib/client-lane/requests";

/**
 * "Decide by" on a request (spec §5.2) — the frndOS v1 `DatePicker`, alone
 * in its file so the v2 request form never imports v1. Optional; the api
 * wants a future day, so today and earlier are disabled.
 */
export function DecideByField({
  value,
  onChange,
  disabled,
}: {
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
}) {
  return (
    <DatePicker
      value={value}
      onChange={onChange}
      min={isoDayFromToday(1)}
      placeholder="No deadline"
      displayFormat="EEE d MMM"
      aria-label="Decide by"
      disabled={disabled}
    />
  );
}
```

Create `src/components/client-lane/agency/ApproverEmailsField.tsx`:

```tsx
"use client";

import clsx from "clsx";
import { useId } from "react";

import { Button, Chip } from "@/components/frndos/v2";

import type { ApproverEmails } from "./useApproverEmails";

/** frndOS has no v2 text input yet; this is the v2 field recipe (glass
 *  fill, white/10 border, ring on keyboard focus, no forms-plugin ring). */
const FIELD =
  "h-10 w-full rounded-xl border border-white/10 bg-white/5 px-3 font-geist text-textSm text-text-inverse outline-none transition-all duration-200 ease-out placeholder:text-text-inverse-subtlest focus:border-white/20 focus:ring-0 focus-visible:ring-2 focus-visible:ring-white/40 disabled:cursor-not-allowed disabled:opacity-50";

/**
 * The approvers of a KV request: committed emails as v2 `Chip`s, the input
 * (Enter / comma / space / blur commits, Backspace on empty removes the
 * last), and the brand's clients as one-tap suggestions.
 */
export function ApproverEmailsField({
  approvers,
  disabled,
}: {
  approvers: ApproverEmails;
  disabled?: boolean;
}) {
  const helpId = useId();
  return (
    <div className="flex flex-col gap-2">
      {approvers.emails.length > 0 && (
        <ul className="flex flex-wrap gap-1.5">
          {approvers.emails.map((email) => (
            <li key={email} className="max-w-full">
              <Chip
                label={email}
                disabled={disabled}
                onRemove={() => approvers.remove(email)}
              />
            </li>
          ))}
        </ul>
      )}
      <input
        type="email"
        aria-label="Approver email"
        aria-describedby={helpId}
        aria-invalid={Boolean(approvers.error)}
        className={FIELD}
        value={approvers.draft}
        disabled={disabled}
        placeholder="dina@brand.co.id — Enter to add"
        onChange={(e) => {
          approvers.setDraft(e.target.value);
          if (approvers.error) approvers.setError(null);
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === "," || e.key === " ") {
            e.preventDefault();
            approvers.add(approvers.draft);
          }
          if (
            e.key === "Backspace" &&
            !approvers.draft &&
            approvers.emails.length > 0
          ) {
            approvers.pop();
          }
        }}
        onBlur={() => {
          if (approvers.draft.trim()) approvers.add(approvers.draft);
        }}
      />
      <p
        id={helpId}
        className={clsx(
          "font-geist text-textXs",
          approvers.error ? "text-negative-400" : "text-text-inverse-subtlest"
        )}
      >
        {approvers.error ??
          (approvers.emails.length === 0
            ? "No names: anyone with the link can decide. Named approvers get a personal link by email."
            : "Each named approver gets their own link by email.")}
      </p>
      {approvers.suggestions.length > 0 && (
        <div className="flex flex-wrap gap-1">
          {approvers.suggestions.map((m) => (
            <Button
              key={m.id}
              type="button"
              variant="text"
              size="tiny"
              disabled={disabled}
              onClick={() => approvers.add(m.email as string)}
            >
              + {m.name ?? m.email}
            </Button>
          ))}
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 5: The form**

Create `src/components/client-lane/agency/KvRequestForm.tsx`:

```tsx
"use client";

import { CaretDown } from "@phosphor-icons/react";
import { useQueryClient } from "@tanstack/react-query";
import clsx from "clsx";
import { useId, useState } from "react";

import { AutoGrowTextarea, Button, FilterChips } from "@/components/frndos/v2";
import {
  failureReason,
  trackApprovalRequestSendFailed,
  trackApprovalRequestSent,
} from "@/lib/analytics/client-lane-events";
import {
  buildRequestPayload,
  plural,
  replacesNote,
} from "@/lib/client-lane/requests";
import {
  approvalApiError,
  approvalRequestsRoot,
  useApprovalRequestPreview,
  useCreateApprovalRequest,
  type CreateApprovalRequestResponse,
} from "@/services/client-lane";
import { useToastStore } from "@/store/useToast";
import { KV_SHARE_PHASE_LABEL, type KvSharePhase } from "@/types/kv/share-link";

import { ApproverEmailsField } from "./ApproverEmailsField";
import { DecideByField } from "./DecideByField";
import { ApprovalSendStep } from "./RequestApprovalPanel";
import { useApproverEmails } from "./useApproverEmails";

const MAX_MESSAGE = 500;
const EYEBROW =
  "font-geist text-textXsMedium uppercase tracking-wider text-text-inverse-subtlest";
const TEXTAREA =
  "rounded-xl border border-white/10 bg-white/5 px-3 py-2.5 font-geist text-textSm text-text-inverse outline-none transition-all duration-200 ease-out placeholder:text-text-inverse-subtlest focus:border-white/20 focus:ring-0 focus-visible:ring-2 focus-visible:ring-white/40";

/**
 * The KV request form (spec 2026-10-01 §5.2) followed by the send step.
 * Rendered INLINE by the share dialog (nesting dialogs breaks focus
 * trapping) — the host swaps its body for this and gets `onDone` back.
 *
 * What goes is decided by the ready marks, not here (Share Link PRD Decision
 * 2): the preview lists every artboard marked ready whose version is not
 * already approved; the phase pills only narrow it.
 */
export function KvRequestForm({
  fileId,
  fileName,
  brandId,
  onDone,
  onCancel,
}: {
  fileId: string;
  fileName: string;
  brandId?: string | null;
  onDone: () => void;
  onCancel: () => void;
}) {
  const [result, setResult] = useState<CreateApprovalRequestResponse | null>(
    null
  );

  if (result) {
    return (
      <ApprovalSendStep
        result={{
          share_url: result.share_url,
          message: result.request.message,
          number: result.request.number,
          approvers: result.approvers,
        }}
        title={fileName}
        subjectType="kv_file"
        headline={`Request ${result.request.number} is out for approval`}
        onDone={onDone}
      />
    );
  }

  return (
    <RequestFields
      fileId={fileId}
      brandId={brandId}
      onSent={setResult}
      onCancel={onCancel}
    />
  );
}

function RequestFields({
  fileId,
  brandId,
  onSent,
  onCancel,
}: {
  fileId: string;
  brandId?: string | null;
  onSent: (result: CreateApprovalRequestResponse) => void;
  onCancel: () => void;
}) {
  const showToast = useToastStore((s) => s.showToast);
  const qc = useQueryClient();
  const preview = useApprovalRequestPreview(fileId);
  const create = useCreateApprovalRequest(fileId);
  const approvers = useApproverEmails(brandId);
  // Phases are ON unless turned off — a phase that becomes ready while the
  // form is open joins the request rather than hiding behind a dead pill.
  const [off, setOff] = useState<KvSharePhase[]>([]);
  const [message, setMessage] = useState("");
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
  const phases = data.phases.map((p) => p.phase).filter((p) => !off.includes(p));
  const items = data.items.filter((item) => phases.includes(item.phase));
  const replaced = items
    .map((item) => replacesNote(item))
    .filter((note): note is string => note !== null);
  // Listed, never sent: the same version already approved, or still pending
  // in another request (api ruling R2). A phase turned off hides its rows.
  const approved = data.already_approved.filter((a) => !off.includes(a.phase));
  const waiting = data.waiting.filter((w) => !off.includes(w.phase));
  /** Another request was created first, or marks moved: re-read the
   *  preview AND the request list. */
  const reread = () =>
    void qc.invalidateQueries({ queryKey: approvalRequestsRoot(fileId) });

  const toggle = (phase: KvSharePhase) =>
    setOff((prev) =>
      prev.includes(phase) ? prev.filter((p) => p !== phase) : [...prev, phase]
    );

  const submit = () => {
    if (create.isPending) return;
    const emails = approvers.commit();
    if (emails === null || phases.length === 0 || items.length === 0) return;
    const payload = buildRequestPayload({ phases, emails, message, decideBy });
    create.mutate(payload, {
      onSuccess: (created) => {
        trackApprovalRequestSent({
          request_number: created.request.number,
          artboard_count: created.request.approvals.length,
          phases: payload.kv_phases,
          approver_count: emails.length,
          has_deadline: Boolean(payload.decide_by),
        });
        onSent(created);
      },
      onError: (error) => {
        const err = approvalApiError(error);
        trackApprovalRequestSendFailed({
          reason: failureReason(err),
          http_status: err.status,
        });
        if (err.code === "already_a_member") {
          approvers.setError(
            `${err.email ?? "That address"} is already a member of this workspace — they can approve from inside frndOS.`
          );
          return;
        }
        // Marks or approvals changed between the preview and the send.
        if (err.code === "nothing_ready") {
          showToast(
            "Nothing new to send",
            "Everything in those phases is approved, waiting, or no longer marked ready. Mark an artboard on the canvas, then send again.",
            "error"
          );
          reread();
          return;
        }
        // `409 round_conflict`: a concurrent request on the same artboards won.
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

      <section className="flex flex-col gap-2">
        <h3 className={EYEBROW}>Phases</h3>
        <FilterChips
          selection="multiple"
          ariaLabel="Phases to send"
          values={phases}
          onToggle={toggle}
          options={data.phases.map((p) => ({
            value: p.phase,
            label: KV_SHARE_PHASE_LABEL[p.phase],
            count: p.count,
          }))}
        />
        <p className="text-textXs text-text-inverse-subtle">
          {phases.length === 0
            ? "Pick at least one phase."
            : `${plural(items.length, "artboard")} in this request`}
        </p>
        {replaced.length > 0 && (
          <ul className="flex flex-col gap-1">
            {replaced.map((note) => (
              <li key={note} className="text-textXs text-text-inverse-subtlest">
                {note}
              </li>
            ))}
          </ul>
        )}
        <ListFold
          label="Already approved"
          rows={approved.map((a) => ({ key: a.subject_key, text: a.label }))}
        />
        <ListFold
          label="Waiting"
          rows={waiting.map((w) => ({
            key: w.subject_key,
            text: `${w.label} — in Request ${w.request_number}`,
          }))}
        />
      </section>

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
            {message.length}/{MAX_MESSAGE}
          </span>
        </div>
        <AutoGrowTextarea
          id={messageId}
          rows={3}
          maxLength={MAX_MESSAGE}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          aria-label="Message"
          placeholder="Craft 1 · Resize 5 — the TikTok cut is new since Tuesday."
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
        <Button type="button" variant="secondary" size="small" onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </form>
  );
}

/** A collapsed list under the phase chips — "Already approved · 3",
 *  "Waiting · 1" (spec §5.2). Nothing for no rows. */
function ListFold({
  label,
  rows,
}: {
  label: string;
  rows: Array<{ key: string; text: string }>;
}) {
  const [open, setOpen] = useState(false);
  const listId = useId();
  if (rows.length === 0) return null;
  return (
    <div>
      <button
        type="button"
        aria-expanded={open}
        aria-controls={listId}
        onClick={() => setOpen((v) => !v)}
        className="flex w-fit items-center gap-1 rounded-md text-textXs text-text-inverse-subtle outline-none transition-all duration-200 ease-out hover:text-text-inverse focus-visible:ring-2 focus-visible:ring-white/40"
      >
        <CaretDown
          size={12}
          aria-hidden
          className={clsx(
            "transition-transform duration-200 ease-out",
            open && "rotate-180"
          )}
        />
        {label} · {rows.length}
      </button>
      {open && (
        <ul id={listId} className="mt-1.5 flex flex-col gap-1 pl-4">
          {rows.map((row) => (
            <li key={row.key} className="text-textXs text-text-inverse-subtlest">
              {row.text}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
```

- [ ] **Step 6: Run the test**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvRequestForm.test.tsx
```

Expected: 11 PASS. If the chip text is not `Craft1` (it is `label` + count span), print `textContent` and fix the expectation only — the markup is FilterChips'.

- [ ] **Step 7: Mutation checks**

1. In `RequestFields`, compute `items` from `data.items` without the phase filter → "narrows by phase…" FAILS. Restore.
2. Drop `phases.length === 0 ||` from the submit guard AND `items.length === 0` from `disabled` → "blocks Send once every phase is off" FAILS. Restore.
3. Remove the `reread();` on `nothing_ready` → "explains nothing_ready and re-reads what is ready" FAILS; remove it on `round_conflict` → "re-reads the preview and the list when another request won the race" FAILS. Restore both.
4. In `trackApprovalRequestSent`'s call, send `has_deadline: true` → "sends approvers and a message…" FAILS. Restore.
5. In `waiting`, drop the `!off.includes(w.phase)` filter → "folds what waits in another request, narrowed by phase" FAILS. Restore.

- [ ] **Step 8: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/analytics/client-lane-events.ts src/components/client-lane/agency/ApproverEmailsField.tsx src/components/client-lane/agency/DecideByField.tsx src/components/client-lane/agency/KvRequestForm.tsx src/components/client-lane/agency/KvRequestForm.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-lane-events|agency/(ApproverEmailsField|DecideByField|KvRequestForm)"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"; /usr/bin/grep -nE -- "-\[[0-9]+px\]|text-white\b|text-gray-" src/components/client-lane/agency/ApproverEmailsField.tsx src/components/client-lane/agency/KvRequestForm.tsx
```

Expected: no tsc grep output; 895; the last grep prints nothing.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/analytics/client-lane-events.ts src/components/client-lane/agency && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): KV approval request form — phases, approvers, message, decide by

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: KvApprovalRequestsSection — the "Approval requests" section

Spec §5.2 section 1 (errors per the api contract: withdraw `409 round_closed`, resend `422 no_named_approvers`): a header button "Request approval · {n} new ready" (n = preview total) that says why when disabled, one row per request (open first, api order) with Copy link, and an expanded row with per-artboard rows (verdict, who, when, pins), approvers with Copy personal link, Resend / Withdraw on an open request.

**Files:**
- Create: `src/components/studio/kv-generator/ShareSectionLabel.tsx`, `src/components/client-lane/agency/KvApprovalRequestsSection.tsx` (v2), `src/components/client-lane/agency/KvApprovalRequestsSection.test.tsx`
- Modify: `src/lib/analytics/client-lane-events.ts`, `src/components/studio/kv-generator/KvSharePanel.tsx` (use `ShareSectionLabel`, delete the local `SectionLabel` lines 391-412)

**Interfaces:**
- Consumes: `useApprovalRequestPreview`, `useApprovalRequests`, `useWithdrawApprovalRequest`, `useResendApprovalRequest`, `AgencyRequest`, `AgencyRequestApproval` (Task 1); `requestTitle`, `requestRowDescription`, `plural` (Task 1); `StatusPill`, `ApproverPill`, `PersonAvatar`, `DecisionList` (Task 3).
- Produces:
  - `KvApprovalRequestsSection({ fileId: string; open: boolean; hasReadyMarks: boolean; onRequest(): void })`
  - `ShareSectionLabel({ children; trailing? })`
  - analytics: `ApprovalRequestFormSource = "share_dialog" | "tray" | "top_bar"`, `trackApprovalRequestFormOpened({ source, ready_total })`, `trackApprovalRequestWithdrawn({ request_number, artboard_count })`, `trackApprovalRequestWithdrawFailed({ request_number, reason, http_status })`, `trackApprovalRequestResent({ request_number, reminded_count })`, `trackApprovalRequestResendFailed({ request_number, reason, http_status })`

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/agency/KvApprovalRequestsSection.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  agencyDecision,
  agencyRequest,
  requestPreview,
} from "@/lib/client-lane/testFixtures";
import type { AgencyRequest } from "@/services/client-lane";
import axiosInstance from "@/services/axios";
import { useToastStore } from "@/store/useToast";

import { KvApprovalRequestsSection } from "./KvApprovalRequestsSection";

const body = () => within(document.body);
const toasts = () => useToastStore.getState().toasts;

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function stubApi(
  requests: AgencyRequest[] = [agencyRequest()],
  preview = requestPreview()
) {
  vi.spyOn(axiosInstance, "get").mockImplementation((async (url: string) => {
    if (url === "v1/approval-requests/preview")
      return { data: { data: preview } };
    if (url === "v1/approval-requests") return { data: { data: requests } };
    throw new Error(`unexpected GET ${url}`);
  }) as never);
  return vi.spyOn(axiosInstance, "post");
}

function renderSection(hasReadyMarks = true) {
  const onRequest = vi.fn();
  render(
    <KvApprovalRequestsSection
      fileId="f1"
      open
      hasReadyMarks={hasReadyMarks}
      onRequest={onRequest}
    />,
    { wrapper: Wrapper }
  );
  return { onRequest };
}

/** Open a row's "•••" and pick a verb (Base UI menu, portalled to body). */
function pick(rowTitle: string, verb: string) {
  fireEvent.click(
    body().getByRole("button", { name: `Actions for ${rowTitle}` })
  );
  fireEvent.click(body().getByRole("menuitem", { name: verb }));
}

let writeText: ReturnType<typeof vi.fn>;
let capture: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  vi.restoreAllMocks();
  useToastStore.getState().clearToasts();
  writeText = vi.fn(async () => undefined);
  Object.defineProperty(navigator, "clipboard", {
    value: { writeText },
    configurable: true,
  });
  capture = vi
    .spyOn(posthog, "capture")
    .mockImplementation(() => undefined as never);
});

describe("KvApprovalRequestsSection — header", () => {
  it("counts what is new and opens the form", async () => {
    stubApi();
    const { onRequest } = renderSection();

    const button = await body().findByRole("button", {
      name: "Request approval · 3 new ready",
    });
    fireEvent.click(button);
    expect(onRequest).toHaveBeenCalled();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_form_opened",
      expect.objectContaining({ source: "share_dialog", ready_total: 3 })
    );
  });

  it("says to mark artboards first when nothing is marked", async () => {
    stubApi([], requestPreview({ phases: [], items: [], total: 0 }));
    renderSection(false);

    expect(
      await body().findByText("Mark artboards ready on the canvas first")
    ).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Request approval" })
    ).toBeDisabled();
  });

  it("says everything is approved or waiting when marks exist but nothing is new", async () => {
    stubApi([], requestPreview({ phases: [], items: [], total: 0 }));
    renderSection(true);

    expect(
      await body().findByText("Everything marked is approved or waiting")
    ).toBeInTheDocument();
  });
});

describe("KvApprovalRequestsSection — rows", () => {
  it("lists each request with its pill and one line", async () => {
    stubApi([
      agencyRequest(),
      agencyRequest({
        id: "rq1",
        number: 1,
        status: "approved",
        counts: {
          approved: 2,
          approved_with_changes: 0,
          changes_required: 0,
          pending: 0,
          superseded: 0,
        },
      }),
    ]);
    renderSection();

    expect(
      await body().findByText("Request 2 · 2 artboards")
    ).toBeInTheDocument();
    expect(body().getByText(/^Waiting on Dina · Decide by /)).toBeInTheDocument();
    expect(body().getByText("Pending")).toBeInTheDocument();
    expect(body().getByText("Approved · 2/2")).toBeInTheDocument();
    // Api order is kept: open first.
    const titles = body()
      .getAllByText(/^Request \d · /)
      .map((n) => n.textContent);
    expect(titles).toEqual(["Request 2 · 2 artboards", "Request 1 · 2 artboards"]);
  });

  it("expands to per-artboard verdicts, pins, deciders and replacements", async () => {
    const replaced = {
      ...agencyRequest().approvals[1],
      id: "ap_r9",
      label: "Resize · TikTok · 1080×1920",
      pin_count: 0,
      superseded_by_request_number: 3,
    };
    stubApi([
      agencyRequest({
        approvals: [...agencyRequest().approvals, replaced],
      }),
    ]);
    renderSection();

    fireEvent.click(
      await body().findByRole("button", {
        name: "Show artboards in Request 2",
      })
    );
    const list = body().getByRole("list", { name: "Artboards in Request 2" });
    expect(within(list).getByText("Craft · Hero board")).toBeInTheDocument();
    expect(within(list).getByText("Approved")).toBeInTheDocument();
    expect(within(list).getByText("Dina")).toBeInTheDocument();
    expect(within(list).getByText("2 pins")).toBeInTheDocument();
    expect(within(list).getByText("Replaced in Request 3")).toBeInTheDocument();
  });

  it("copies the request's own link from the row menu", async () => {
    stubApi();
    renderSection();

    await body().findByText("Request 2 · 2 artboards");
    pick("Request 2 · 2 artboards", "Copy link");
    await waitFor(() =>
      expect(writeText).toHaveBeenCalledWith("https://frndos.test/s/req_tok")
    );
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_link_shared",
      expect.objectContaining({ round: 2, channel: "copy" })
    );
  });

  it("copies a named approver's personal link while the request is open", async () => {
    stubApi();
    renderSection();

    fireEvent.click(
      await body().findByRole("button", {
        name: "Show artboards in Request 2",
      })
    );
    fireEvent.click(
      body().getByRole("button", { name: "Copy Dina's personal link" })
    );
    await waitFor(() =>
      expect(writeText).toHaveBeenCalledWith(
        "https://frndos.test/s/req_tok?k=lanecode"
      )
    );
  });

  it("withdraws only after confirming, and reports it", async () => {
    const post = stubApi();
    post.mockResolvedValue({
      data: { data: agencyRequest({ status: "not_relevant" }) },
    } as never);
    renderSection();

    await body().findByText("Request 2 · 2 artboards");
    pick("Request 2 · 2 artboards", "Withdraw");
    expect(post).not.toHaveBeenCalled();
    fireEvent.click(body().getByRole("button", { name: "Withdraw request" }));

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith("v1/approval-requests/rq2/withdraw")
    );
    await waitFor(() =>
      expect(capture).toHaveBeenCalledWith(
        "client_lane.approval_request_withdrawn",
        expect.objectContaining({ request_number: 2, artboard_count: 2 })
      )
    );
  });

  it("reports a failed resend with the api's reason", async () => {
    const post = stubApi();
    post.mockRejectedValue({
      response: { status: 422, data: { code: "no_named_approvers" } },
    });
    renderSection();

    await body().findByText("Request 2 · 2 artboards");
    pick("Request 2 · 2 artboards", "Resend");
    await waitFor(() => expect(toasts()[0]?.title).toBe("Couldn't resend"));
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_resend_failed",
      expect.objectContaining({
        request_number: 2,
        reason: "no_named_approvers",
        http_status: 422,
      })
    );
  });

  it("re-reads the list when the request closed before the withdraw landed", async () => {
    const post = stubApi();
    post.mockRejectedValue({
      response: { status: 409, data: { code: "round_closed" } },
    });
    // spyOn replaced the method; bun has no vi.mocked.
    const get = axiosInstance.get as unknown as { mock: { calls: unknown[][] } };
    renderSection();

    await body().findByText("Request 2 · 2 artboards");
    const reads = get.mock.calls.filter(
      ([u]) => u === "v1/approval-requests"
    ).length;
    pick("Request 2 · 2 artboards", "Withdraw");
    fireEvent.click(body().getByRole("button", { name: "Withdraw request" }));

    await waitFor(() =>
      expect(toasts()[0]?.title).toBe("This request is already closed")
    );
    await waitFor(() =>
      expect(
        get.mock.calls.filter(([u]) => u === "v1/approval-requests").length
      ).toBeGreaterThan(reads)
    );
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_withdraw_failed",
      expect.objectContaining({ reason: "round_closed", http_status: 409 })
    );
  });

  it("offers no Resend or Withdraw on a closed request, and no copy once its link is gone", async () => {
    stubApi([
      agencyRequest({
        status: "approved",
        share_link_active: false,
        approvals: [
          {
            ...agencyRequest().approvals[0],
            decisions: [agencyDecision()],
          },
        ],
      }),
    ]);
    renderSection();

    const title = "Request 2 · 1 artboard";
    await body().findByText(title);
    fireEvent.click(
      body().getByRole("button", { name: `Actions for ${title}` })
    );
    expect(body().queryByRole("menuitem", { name: "Resend" })).toBeNull();
    expect(body().queryByRole("menuitem", { name: "Withdraw" })).toBeNull();
    expect(body().getByRole("menuitem", { name: "Copy link" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );
  });
});
```

- [ ] **Step 2: Run it to watch it fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvApprovalRequestsSection.test.tsx
```

Expected: FAIL — module not found.

- [ ] **Step 3: Analytics helpers**

Append after `trackApprovalRequestSendFailed` in `src/lib/analytics/client-lane-events.ts`:

```ts

/** Where a KV request form was opened (Part B adds the tray and top bar). */
export type ApprovalRequestFormSource = "share_dialog" | "tray" | "top_bar";

export const trackApprovalRequestFormOpened = (props: {
  source: ApprovalRequestFormSource;
  /** The preview total at the click: artboards a request would hold. */
  ready_total: number;
}) => safeCapture("client_lane.approval_request_form_opened", props);

export const trackApprovalRequestWithdrawn = (props: {
  request_number: number;
  artboard_count: number;
}) => safeCapture("client_lane.approval_request_withdrawn", props);

export const trackApprovalRequestWithdrawFailed = (props: {
  request_number: number;
  reason: string;
  http_status: number | null;
}) => safeCapture("client_lane.approval_request_withdraw_failed", props);

export const trackApprovalRequestResent = (props: {
  request_number: number;
  /** Named approvers re-mailed. */
  reminded_count: number;
}) => safeCapture("client_lane.approval_request_resent", props);

export const trackApprovalRequestResendFailed = (props: {
  request_number: number;
  reason: string;
  http_status: number | null;
}) => safeCapture("client_lane.approval_request_resend_failed", props);
```

- [ ] **Step 4: Lift the dialog's section label**

Create `src/components/studio/kv-generator/ShareSectionLabel.tsx` (moved verbatim from `KvSharePanel.tsx` lines 391-412 so the request section — another file — uses the same label):

```tsx
import type { ReactNode } from "react";

/** The share dialog's uppercase section label — "VIEW LINKS", "APPROVAL
 *  REQUESTS", the create form's field labels — with an optional trailing slot. */
export function ShareSectionLabel({
  children,
  trailing,
}: {
  children: ReactNode;
  trailing?: ReactNode;
}) {
  return (
    <div className="mb-2 flex items-center justify-between">
      <span className="font-geist text-textXsMedium uppercase tracking-[0.08em] text-text-inverse-subtlest">
        {children}
      </span>
      {trailing && (
        <span className="font-geist text-textXs text-text-inverse-subtlest">
          {trailing}
        </span>
      )}
    </div>
  );
}
```

In `KvSharePanel.tsx` delete the local `SectionLabel` (lines 391-412), add `import { ShareSectionLabel as SectionLabel } from "./ShareSectionLabel";` beside the `./kvShareCuration` import, and leave every `<SectionLabel>` call as is.

- [ ] **Step 5: The section**

Create `src/components/client-lane/agency/KvApprovalRequestsSection.tsx`:

```tsx
"use client";

import { CaretDown, Check, Copy, SealCheck } from "@phosphor-icons/react";
import { useQueryClient } from "@tanstack/react-query";
import clsx from "clsx";
import { useId, useState } from "react";

import { ActionMenu, Button, ItemRow } from "@/components/frndos/v2";
import { ShareSectionLabel } from "@/components/studio/kv-generator/ShareSectionLabel";
import {
  failureReason,
  trackApprovalLinkShared,
  trackApprovalRequestFormOpened,
  trackApprovalRequestResendFailed,
  trackApprovalRequestResent,
  trackApprovalRequestWithdrawFailed,
  trackApprovalRequestWithdrawn,
  trackApproverLinkCopied,
  trackApproverLinkCopyFailed,
} from "@/lib/analytics/client-lane-events";
import {
  plural,
  requestRowDescription,
  requestTitle,
} from "@/lib/client-lane/requests";
import {
  approvalApiError,
  approvalRequestsRoot,
  useApprovalRequestPreview,
  useApprovalRequests,
  useResendApprovalRequest,
  useWithdrawApprovalRequest,
  type AgencyRequest,
  type AgencyRequestApproval,
} from "@/services/client-lane";
import { useToastStore } from "@/store/useToast";

import { ApproverPill, StatusPill } from "../StatusPill";
import { DecisionList } from "./DecisionRow";
import { PersonAvatar } from "./PersonAvatar";

const QUIET = "font-geist text-textXs text-text-inverse-subtlest";
const DISCLOSURE =
  "flex size-6 items-center justify-center rounded-md text-icon-inverse-subtlest outline-none transition-all duration-200 ease-out hover:bg-white/10 hover:text-icon-inverse-default focus-visible:ring-2 focus-visible:ring-white/40";

/**
 * The share dialog's "Approval requests" section (spec 2026-10-01 §5.2):
 * the way into a request and the state of every request on the file. Reads
 * `GET v1/approval-requests` — the same list Part B's chips and popover read,
 * so their counts agree.
 */
export function KvApprovalRequestsSection({
  fileId,
  open,
  hasReadyMarks,
  onRequest,
}: {
  fileId: string;
  /** Gate the queries — only while the dialog is open. */
  open: boolean;
  /** Anything on the file marked ready (the disabled reason tells them apart). */
  hasReadyMarks: boolean;
  onRequest: () => void;
}) {
  const preview = useApprovalRequestPreview(fileId, { enabled: open });
  const requests = useApprovalRequests(fileId, { enabled: open });
  const total = preview.data?.total ?? 0;
  // Said in words, not a hover hint: a disabled reason has to be readable
  // on touch and by keyboard too (spec §5.2 "it says why").
  const reason = preview.isLoading
    ? null
    : !hasReadyMarks
      ? "Mark artboards ready on the canvas first"
      : total === 0
        ? "Everything marked is approved or waiting"
        : null;
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
                source: "share_dialog",
                ready_total: total,
              });
              onRequest();
            }}
          >
            {total > 0 ? `Request approval · ${total} new ready` : "Request approval"}
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
              <RequestRow request={request} fileId={fileId} />
            </li>
          ))}
        </ul>
      ) : requests.isSuccess ? (
        <p className={QUIET}>No requests yet.</p>
      ) : null}
    </section>
  );
}

function RequestRow({
  request,
  fileId,
}: {
  request: AgencyRequest;
  fileId: string;
}) {
  const showToast = useToastStore((s) => s.showToast);
  const qc = useQueryClient();
  const withdraw = useWithdrawApprovalRequest(fileId);
  const resend = useResendApprovalRequest();
  const [expanded, setExpanded] = useState(false);
  const [confirmWithdraw, setConfirmWithdraw] = useState(false);
  const panelId = useId();
  const open = request.status === "pending";
  const linkLive = request.share_link_active;
  const title = requestTitle(request);

  const copyLink = async () => {
    if (!request.share_url) return;
    try {
      await navigator.clipboard.writeText(request.share_url);
      trackApprovalLinkShared({
        subject_type: "kv_file",
        round: request.number,
        channel: "copy",
      });
      showToast("Link copied", request.share_url, "success");
    } catch {
      showToast("Link ready", request.share_url, "info");
    }
  };

  const doResend = () =>
    resend.mutate(request.id, {
      onSuccess: (sent) => {
        trackApprovalRequestResent({
          request_number: request.number,
          reminded_count: sent.length,
        });
        showToast(
          "Reminder sent",
          sent.length ? sent.join(", ") : "No one to remind.",
          "success"
        );
      },
      onError: (error) => {
        const err = approvalApiError(error);
        trackApprovalRequestResendFailed({
          request_number: request.number,
          reason: failureReason(err),
          http_status: err.status,
        });
        showToast(
          "Couldn't resend",
          err.message ?? "Try again in a moment.",
          "error"
        );
      },
    });

  const doWithdraw = () =>
    withdraw.mutate(request.id, {
      onSuccess: () => {
        trackApprovalRequestWithdrawn({
          request_number: request.number,
          artboard_count: request.approvals.length,
        });
        setConfirmWithdraw(false);
        showToast(
          "Request withdrawn",
          "Its link stays readable; nobody can decide on it.",
          "success"
        );
      },
      onError: (error) => {
        const err = approvalApiError(error);
        trackApprovalRequestWithdrawFailed({
          request_number: request.number,
          reason: failureReason(err),
          http_status: err.status,
        });
        setConfirmWithdraw(false);
        // `409 round_closed`: it was decided (or withdrawn) meanwhile.
        if (err.code === "round_closed") {
          showToast(
            "This request is already closed",
            "It was decided or withdrawn while you were here — the list is up to date now.",
            "info"
          );
          void qc.invalidateQueries({ queryKey: approvalRequestsRoot(fileId) });
          return;
        }
        showToast(
          "Couldn't withdraw",
          err.message ?? "Try again in a moment.",
          "error"
        );
      },
    });

  const verbs = [
    {
      id: "copy",
      label: "Copy link",
      icon: <Copy size={14} />,
      onSelect: () => void copyLink(),
      disabled: !linkLive || !request.share_url,
    },
    ...(open && linkLive && request.approvers.length > 0
      ? [{ id: "resend", label: "Resend", onSelect: doResend }]
      : []),
    ...(open
      ? [
          {
            id: "withdraw",
            label: "Withdraw",
            tone: "danger" as const,
            onSelect: () => setConfirmWithdraw(true),
          },
        ]
      : []),
  ];

  return (
    <div>
      <ItemRow
        icon={
          <ItemRow.Glyph>
            <SealCheck size={16} />
          </ItemRow.Glyph>
        }
        title={title}
        badge={<StatusPill status={request.status} />}
        description={
          linkLive
            ? requestRowDescription(request)
            : `${requestRowDescription(request)} · Link no longer active`
        }
        trailing={
          <>
            <ActionMenu ariaLabel={`Actions for ${title}`} items={verbs} />
            <button
              type="button"
              aria-expanded={expanded}
              aria-controls={panelId}
              aria-label={`${expanded ? "Hide" : "Show"} artboards in Request ${request.number}`}
              onClick={() => setExpanded((v) => !v)}
              className={DISCLOSURE}
            >
              <CaretDown
                size={14}
                aria-hidden
                className={clsx(
                  "transition-transform duration-200 ease-out",
                  expanded && "rotate-180"
                )}
              />
            </button>
          </>
        }
      />
      {confirmWithdraw && (
        <div
          role="group"
          aria-label={`Withdraw ${title}?`}
          className="ml-12 mt-1 flex flex-wrap items-center gap-2 rounded-xl border border-white/10 bg-white/5 p-3"
        >
          <p className="w-full font-geist text-textXs text-text-inverse-subtle">
            Nobody can decide on its artboards after this. Their decisions so
            far stay on record.
          </p>
          <Button
            variant="alertSecondary"
            size="small"
            loading={withdraw.isPending}
            disabled={withdraw.isPending}
            onClick={doWithdraw}
          >
            Withdraw request
          </Button>
          <Button
            variant="text"
            size="small"
            disabled={withdraw.isPending}
            onClick={() => setConfirmWithdraw(false)}
          >
            Keep
          </Button>
        </div>
      )}
      {expanded && <RequestDetail id={panelId} request={request} />}
    </div>
  );
}

function RequestDetail({
  id,
  request,
}: {
  id: string;
  request: AgencyRequest;
}) {
  const showToast = useToastStore((s) => s.showToast);
  const [copied, setCopied] = useState<string | null>(null);
  const live = request.status === "pending" && request.share_link_active;

  const copyPersonal = async (email: string, name: string, url: string) => {
    const where = { subject_type: "kv_file" as const, round: request.number };
    try {
      await navigator.clipboard.writeText(url);
    } catch {
      trackApproverLinkCopyFailed(where);
      showToast(
        "Couldn't copy",
        "Copy the link from the request email instead.",
        "error"
      );
      return;
    }
    trackApproverLinkCopied(where);
    setCopied(email);
    window.setTimeout(() => setCopied((e) => (e === email ? null : e)), 2000);
    showToast(
      "Personal link copied",
      `Only ${name} should open it — a decision from it counts as theirs.`,
      "success"
    );
  };

  return (
    <div
      id={id}
      className="ml-12 mt-1 flex flex-col gap-4 border-l border-white/5 pb-2 pl-3"
    >
      <ul
        aria-label={`Artboards in Request ${request.number}`}
        className="flex flex-col gap-3"
      >
        {request.approvals.map((approval) => (
          <ArtboardRow key={approval.id} approval={approval} />
        ))}
      </ul>
      {request.approvers.length > 0 && (
        <ul aria-label="Approvers" className="flex flex-col gap-2">
          {request.approvers.map((person) => {
            const name = person.name || person.email;
            return (
              <li key={person.email} className="flex items-center gap-2.5">
                <PersonAvatar name={name} />
                <span className="min-w-0 flex-1 truncate font-geist text-textXs text-text-inverse">
                  {name}
                </span>
                <ApproverPill decided={person.decided} />
                {live && person.personal_url ? (
                  <Button
                    variant="icon"
                    size="tiny"
                    aria-label={`Copy ${name}'s personal link`}
                    onClick={() =>
                      void copyPersonal(
                        person.email,
                        name,
                        person.personal_url as string
                      )
                    }
                  >
                    {copied === person.email ? (
                      <Check size={12} />
                    ) : (
                      <Copy size={12} />
                    )}
                  </Button>
                ) : null}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

function ArtboardRow({ approval }: { approval: AgencyRequestApproval }) {
  return (
    <li className="flex flex-col gap-1.5">
      <div className="flex items-center gap-2">
        {approval.thumbnail_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={approval.thumbnail_url}
            alt=""
            className="size-8 shrink-0 rounded-md object-cover"
          />
        ) : (
          <span aria-hidden className="size-8 shrink-0 rounded-md bg-white/10" />
        )}
        <span className="min-w-0 flex-1 truncate font-geist text-textXs text-text-inverse">
          {approval.label}
        </span>
        {approval.pin_count > 0 && (
          <span className={clsx("shrink-0", QUIET)}>
            {plural(approval.pin_count, "pin")}
          </span>
        )}
        {approval.superseded_by_request_number !== null ? (
          <span className={clsx("shrink-0", QUIET)}>
            Replaced in Request {approval.superseded_by_request_number}
          </span>
        ) : (
          <StatusPill status={approval.status} />
        )}
      </div>
      <DecisionList decisions={approval.decisions} />
    </li>
  );
}
```

- [ ] **Step 6: Run the test and the panel suite**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvApprovalRequestsSection.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: 11 PASS; KvSharePanel unchanged count. If Base UI renders a disabled menu item with `data-disabled` but no `aria-disabled`, print the item's attributes and assert the one it has.

- [ ] **Step 7: Mutation checks**

1. Swap the two reason branches (`!hasReadyMarks` ↔ `total === 0`) → "says to mark artboards first…" FAILS. Restore.
2. Call `doWithdraw` straight from the menu's `onSelect` → "withdraws only after confirming" FAILS (`post` called before the confirm). Restore.
3. Drop the `open &&` guard on the Withdraw verb → "offers no Resend or Withdraw on a closed request…" FAILS. Restore.
4. Render `<StatusPill status={approval.status} />` even when superseded → "expands to … replacements" FAILS. Restore.
5. Drop the `qc.invalidateQueries(…)` in the `round_closed` branch → "re-reads the list when the request closed before the withdraw landed" FAILS. Restore.

- [ ] **Step 8: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/analytics/client-lane-events.ts src/components/studio/kv-generator/ShareSectionLabel.tsx src/components/studio/kv-generator/KvSharePanel.tsx src/components/client-lane/agency/KvApprovalRequestsSection.tsx src/components/client-lane/agency/KvApprovalRequestsSection.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-lane-events|ShareSectionLabel|KvSharePanel|KvApprovalRequestsSection"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"; /usr/bin/grep -nE -- "-\[[0-9]+px\]|text-white\b|text-gray-" src/components/client-lane/agency/KvApprovalRequestsSection.tsx
```

Expected: nothing, 895, nothing.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/analytics/client-lane-events.ts src/components/studio/kv-generator/ShareSectionLabel.tsx src/components/studio/kv-generator/KvSharePanel.tsx src/components/client-lane/agency && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): Approval requests section — one row per request, per-artboard detail

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: KvSharePanel — two sections, the New-link toggle removed

Spec §5.2: "Approval requests" first, "View links" below (unchanged, `1/3`); the New-link form is access-only again (revert of `6ed9386e8` in behaviour); `ApprovalStatusBlock` no longer renders for `kv_file`.

**Files:**
- Modify: `src/components/studio/kv-generator/KvSharePanel.tsx`, `src/components/studio/kv-generator/KvSharePanel.test.tsx` (replace the `describe("KvSharePanel — Request approval toggle", …)` block, lines 635-1016), `src/components/client-lane/agency/RequestApprovalPanel.tsx` (drop the KV branch), `src/lib/analytics/client-lane-events.ts` (drop `trackApprovalModeToggled`, `"link_toggle"`)

**Interfaces:**
- Consumes: `KvApprovalRequestsSection` (Task 5), `KvRequestForm` (Task 4).
- Produces: nothing new; `useApprovalRequestForm` loses `kvPhases` / `kvMissing`; `ApprovalRequestEntry` becomes `"request_another" | "request_button"`.

- [ ] **Step 1: Write the failing tests**

In `src/components/studio/kv-generator/KvSharePanel.test.tsx` delete lines 635-1016 (the whole toggle suite, including its doc comment) and append:

```tsx
/**
 * Client lane on (spec 2026-10-01 §5.2). The network edge is `axiosInstance`
 * — spied per test, never `vi.mock`ed.
 */
describe("KvSharePanel — approval requests", () => {
  function stubRequestsApi() {
    return vi
      .spyOn(axiosInstance, "get")
      .mockImplementation(async (url: string) => {
        if (url === "v1/approval-requests/preview")
          return {
            data: {
              data: {
                phases: [{ phase: "craft", count: 1 }],
                items: [
                  {
                    subject_key: "board:c1",
                    phase: "craft",
                    label: "Craft · Hero board",
                    version_id: "c1",
                    thumbnail_url: null,
                    replaces: null,
                  },
                ],
                already_approved: [],
                waiting: [],
                total: 1,
              },
            },
          };
        if (url === "v1/approval-requests") return { data: { data: [] } };
        throw new Error(`unexpected GET ${url}`);
      });
  }

  beforeEach(() => {
    clientLaneOn = true;
  });

  it("puts Approval requests above View links", async () => {
    stubRequestsApi();
    useKvShareLinks.mockReturnValue({ data: [link()], isLoading: false });
    renderPanel();

    const requests = await body().findByText("Approval requests");
    const views = body().getByText("View links");
    expect(
      requests.compareDocumentPosition(views) &
        Node.DOCUMENT_POSITION_FOLLOWING
    ).toBeTruthy();
    expect(body().getByText("1/3")).toBeInTheDocument();
  });

  it("has no Request approval toggle in the New-link form any more", async () => {
    stubRequestsApi();
    const user = userEvent.setup();
    renderPanel();

    await openCreateForm(user);
    expect(
      body().queryByRole("switch", { name: "Request approval" })
    ).toBeNull();
    // Access-only: expiry, label, passcode, Create link.
    expect(body().getByText("Expiration duration")).toBeInTheDocument();
    expect(body().getByLabelText("Link label")).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Create link" })
    ).toBeInTheDocument();
    expect(body().queryByLabelText("Approver email")).toBeNull();
  });

  it("opens the request form from the section and comes back on Cancel", async () => {
    stubRequestsApi();
    const user = userEvent.setup();
    renderPanel();

    await user.click(
      await body().findByRole("button", {
        name: "Request approval · 1 new ready",
      })
    );
    expect(
      await body().findByRole("group", { name: "Phases to send" })
    ).toBeInTheDocument();
    await user.click(body().getByRole("button", { name: "Cancel" }));
    expect(await body().findByText("Approval requests")).toBeInTheDocument();
  });

  it("no longer reads v1/approvals for a key visual", async () => {
    const get = stubRequestsApi();
    renderPanel();

    await body().findByText("Approval requests");
    expect(get.mock.calls.some(([u]) => u === "v1/approvals")).toBe(false);
  });

  it("shows neither section nor request calls while the lane is off", async () => {
    clientLaneOn = false;
    const get = vi.spyOn(axiosInstance, "get");
    useKvShareLinks.mockReturnValue({ data: [link()], isLoading: false });
    renderPanel();

    await body().findByText("Active links");
    expect(body().queryByText("Approval requests")).toBeNull();
    expect(get).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run them to watch them fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: the first four new tests FAIL (no section; the toggle still renders; `v1/approvals` is read); the lane-off test passes.

- [ ] **Step 3: Rewire `KvSharePanel.tsx`**

- Imports: keep `Toggle` (the passcode row uses it); remove `useQueryClient`, `SealCheck`, `kvShareLinksKey`, `ApprovalStatusBlock`, `ApprovalFields`/`ApprovalSendStep`/`sendStepResultOfRound`/`useApprovalRequestForm`, `trackApprovalModeToggled`/`ApprovalRequestEntry`, `approvalsKey`/`useApprovals`/`CreateApprovalResponse`. Add:

```tsx
import { KvApprovalRequestsSection } from "@/components/client-lane/agency/KvApprovalRequestsSection";
import { KvRequestForm } from "@/components/client-lane/agency/KvRequestForm";
```

- In `KvSharePanel` (lines 132-389): drop `queryClient`, the `approvals` / `currentRound` / `pendingRound` block (146-153). `creating` becomes `const [creating, setCreating] = useState(false);` and add `const [requesting, setRequesting] = useState(false);`. Before `if (creating)` add:

```tsx
  if (requesting) {
    return (
      <KvRequestForm
        fileId={fileId}
        fileName={fileName}
        brandId={brandId}
        onDone={() => setRequesting(false)}
        onCancel={() => setRequesting(false)}
      />
    );
  }
```

  `if (creating)` renders `<CreateLinkForm items={items} readyToShareMap={readyToShareMap} pending={mutations.create.isPending} atLimit={atLimit} onCancel={() => setCreating(false)} onSubmit={…} />` (the `approval` prop is gone; `onSuccess` calls `setCreating(false)`). Every `setCreating("link")` becomes `setCreating(true)`.
- The returned JSX opens with:

```tsx
    <div className="space-y-3">
      {clientLane && (
        <>
          <KvApprovalRequestsSection
            fileId={fileId}
            open={open}
            hasReadyMarks={canCreateLink}
            onRequest={() => setRequesting(true)}
          />
          <div aria-hidden className="border-t border-white/5" />
        </>
      )}
```

  The header label (line 254) reads `{clientLane ? "View links" : "Active links"}` — two sections need telling apart; with the lane off the panel is byte-identical to today.
- The EmptyState description (lines 310-318) drops the client-lane branch: `"Create a link to let clients review this key visual — no sign-in needed."` (view links no longer approve).
- `ShareLinkRow`: drop the `pendingRound` prop, its doc line, the `pendingRound={…}` argument (339-343) and the amber paragraph (467-472). The revoke `onSuccess` keeps only `trackKvShareLinkToggled(…)` (the `approvalsKey` invalidation goes — a view link carries no request).
- Delete the bottom `{clientLane && (<div className="pt-1"><ApprovalStatusBlock …/></div>)}` block and its comment (373-386).
- Delete `ApprovalModeProps` (601-611), `KvApprovalForm` (961-1018). `CreateLinkForm` loses the `approval` prop, `approvalOn` / `sent` state, the `if (approval && sent)` branch, the toggle card (724-759) and the `approval && showApprovalFields ? … :` branch — its body is the former `else` fragment, and the Create-link button's `disabled` / `title` comment about "Request round N" goes. Its doc comment becomes:

```tsx
/** Create form — stage pills (each carrying its live shared count), expiry
 *  pills, label, passcode. No per-item picker and no marking controls: a
 *  stage's contents are whatever is marked ready to share (§8.13), and
 *  marking is a canvas action. Access only — approval is asked for in the
 *  "Approval requests" section (spec 2026-10-01 §5.2). */
```

- `StageScopeField`'s doc comment: "…the create form's scope control (spec §6.1)" → "the create form's scope control".

- [ ] **Step 4: Strip the KV branch from the deck/plan form and the dead analytics**

In `RequestApprovalPanel.tsx`'s `useApprovalRequestForm`: delete the `kvPhases` parameter + doc, `kvMissing`, the `if (kvMissing) return;`, the phases snapshot, and the `...(subjectType === "kv_file" ? { kv_phases: phases } : {})` spread; `trackApprovalRequested` sends `item_count: created.approval.items?.length ?? 1, phases: []`; the `nothing_ready` / `too_many_items` branches go (only KV raised them); `RequestForm`'s Create-link `disabled` becomes `form.pending`; the return object drops `kvMissing`. Delete the `KvSharePhase` import and update the file's header comment: "The deck and plan sheets use this whole panel; a key visual asks through `KvRequestForm` (spec 2026-10-01)."

The approver field of `ApprovalFields` moves to the v2 `ApproverEmailsField` (Task 4), which ends this file's existing v1/v2 mix (it imported the v2 `Chip` beside v1 `Button`/`Input`/`PillTabs`/`TextArea` — spec §11.1 "one file never mixes"). `useApprovalRequestForm` returns `approvers` (the `useApproverEmails` object) in place of the nine flattened email keys (`emails`, `emailDraft`, `setEmailDraft`, `emailError`, `setEmailError`, `addEmail`, `removeEmail`, `popEmail`, `suggestions`), and `ApprovalFields`' first `<section>` becomes:

```tsx
      <section>
        <FieldLabel>Approvers · optional</FieldLabel>
        <ApproverEmailsField approvers={form.approvers} disabled={form.pending} />
      </section>
```

Imports: add `import { ApproverEmailsField } from "./ApproverEmailsField";`; drop `Input`, `PillTabs` from the v1 import and the whole `@/components/frndos/v2` (`Chip`) import. The deck / plan field looks like the KV one now and behaves the same (same validation, same label, same helper text) — `RequestApprovalPanel.test.tsx` proves it.

In `client-lane-events.ts`: delete `trackApprovalModeToggled` (lines 63-67); `ApprovalRequestEntry` becomes:

```ts
/**
 * Where a deck / plan request-approval form was opened from:
 * - `request_another` — "Request round N" on the status block.
 * - `request_button` — the standalone Request approval entry.
 */
export type ApprovalRequestEntry = "request_another" | "request_button";
```

Verify nothing else references them:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/grep -rn "trackApprovalModeToggled\|link_toggle\|kvMissing\|kv_ready_item_id\|emailDraft" src; /usr/bin/grep -n "components/frndos/v2" src/components/client-lane/agency/RequestApprovalPanel.tsx
```

Expected: no output from either grep.

- [ ] **Step 5: Run the suites**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/RequestApprovalPanel.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/brands/campaign-planner/SharePlanDialog.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && wc -c src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: all PASS; the test file ≈ 26 KB (< 45 KB).

- [ ] **Step 6: Mutation checks**

1. Move the `{clientLane && (<> <KvApprovalRequestsSection …/> … </>)}` block below the view links list → "puts Approval requests above View links" FAILS. Restore.
2. Re-add `<ApprovalStatusBlock subjectType="kv_file" subjectId={fileId} enabled={open} />` under the list → "no longer reads v1/approvals for a key visual" FAILS. Restore.

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/studio/kv-generator/KvSharePanel.tsx src/components/studio/kv-generator/KvSharePanel.test.tsx src/components/client-lane/agency/RequestApprovalPanel.tsx src/lib/analytics/client-lane-events.ts) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "KvSharePanel|RequestApprovalPanel|client-lane-events|DeckShareLinks|SharePlanDialog|KvCanvasTopNav|KvMotionEditor"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: nothing; 895.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/studio/kv-generator src/components/client-lane/agency/RequestApprovalPanel.tsx src/lib/analytics/client-lane-events.ts && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): KV share dialog — Approval requests above View links; New link is access-only again

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Request model + KvRequestHero

The client page's left column (spec §5.1): a grid of artboards grouped by phase on `KvPhaseGrid`, each card showing its state (`No decision yet`, `Approved`, `Approved with fixes`, `New version asked`, `Replaced by a newer version`) and quick ✓ / ✎; a tapped card opens `KvFocusedItem` with its pin layer.

**Files:**
- Create: `src/components/client-lane/kv/requestItems.ts`, `src/components/client-lane/kv/requestItems.test.ts`, `src/components/client-lane/kv/KvRequestHero.tsx`, `src/components/client-lane/kv/KvRequestHero.test.tsx`
- Modify: `src/components/client-lane/kv/roundItems.ts` (export `findInDocument`, line 44), `src/components/client-lane/kv/KvPhaseGrid.tsx`, `src/components/client-lane/kv/KvFocusedItem.tsx`

**Interfaces:**
- Consumes: `RequestView`, `requestOf` (Task 1); `artboardStateOf`, `stateOfOutcome`, `ArtboardState` (Task 1); `ArtboardStatePill` (Task 3); `KvRoundItem`, `itemLabel`, `kvItemPart` (existing).
- Produces:
  - `RequestArtboard extends KvRoundItem { round: number; status: ApprovalStatus; replaced: boolean; decisions: ApprovalDecision[]; state: ArtboardState; decidable: boolean }` (`id` = the approval id, `caption` = "{Phase} · {item label}")
  - `requestArtboards(document: PublicKvResponse, view: RequestView, viewerName: string | null): RequestArtboard[]`
  - `requestVersionIds(view: RequestView): ReadonlySet<string>`
  - `RequestProgress { decided; total; approved; newVersions; complete }`, `requestProgress(artboards)`, `progressLabel(p)`, `completionSummary(p)`
  - `ApproveAllPlan { ids: string[]; skippedWithPins: number }`, `approveAllPlan(artboards, pinnedVersions: ReadonlySet<string>)`, `approveAllLabel(plan)`
  - `nextUndecided(artboards, currentId: string | null): RequestArtboard | null`
  - `ArtboardIntent = "approve" | "new_version"`; `KvRequestHero(props: KvRequestHeroProps)` with `{ artboards; pins; draft; activePinId; focusedId; onFocusChange; keyboardEnabled; onPlacePin?(a, x, y); onSelectPin; onDecide?(a, intent); busy }`
  - `KvGridCard` gains `badge?`, `actions?`, `muted?`; `KvPhaseGrid` gains `columns?: 1 | 2`; `KvFocusedItem` gains `noun?: string`

- [ ] **Step 1: Write the failing model test**

Create `src/components/client-lane/kv/requestItems.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { requestOf } from "@/lib/client-lane/requests";
import {
  FEED,
  HERO,
  STORY,
  agencyDecision,
  kvRequest,
  requestApproval,
} from "@/lib/client-lane/testFixtures";
import type { ShareLinkKv } from "@/lib/client-lane/types";

import {
  approveAllLabel,
  approveAllPlan,
  completionSummary,
  nextUndecided,
  progressLabel,
  requestArtboards,
  requestProgress,
  requestVersionIds,
} from "./requestItems";

const build = (data: ShareLinkKv = kvRequest(), viewer: string | null = "Dina") =>
  requestArtboards(data.document, requestOf(data)!, viewer);

describe("requestArtboards", () => {
  it("draws every artboard from its snapshot, in request order", () => {
    const artboards = build();
    expect(
      artboards.map((a) => [a.id, a.caption, a.state, a.decidable])
    ).toEqual([
      ["ra_g1", "Craft · Hero board", "undecided", true],
      ["ra_r1", "Resize · IG Story · 1080 × 1920", "undecided", true],
      ["ra_r2", "Resize · IG Feed · 1080 × 1080", "undecided", true],
    ]);
    expect(artboards[1].part).toBe("tile.r1");
    expect(artboards[1].versionId).toBe("r1");
  });

  it("falls back to the live payload without a snapshot, and skips what is gone", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(HERO, "craft", { snapshot: null }),
        requestApproval(STORY, "resize", { snapshot: null, version_id: "gone" }),
      ],
    });
    expect(build(data).map((a) => a.id)).toEqual(["ra_g1"]);
  });

  it("reads the viewer's own answer on a still-pending artboard", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(HERO, "craft", {
          decisions: [agencyDecision({ actor: "Dina", outcome: "approved" })],
        }),
        requestApproval(STORY, "resize", {
          decisions: [
            agencyDecision({ actor: "Bayu", outcome: "changes_required" }),
          ],
        }),
      ],
    });
    const [hero, story] = build(data);
    expect(hero.state).toBe("approved");
    expect(hero.decidable).toBe(true);
    expect(story.state).toBe("undecided");
    expect(build(data, null)[0].state).toBe("undecided");
  });

  it("lets the viewer's latest answer win and ignores a deferral", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(HERO, "craft", {
          decisions: [
            agencyDecision({ id: "a", decided_at: "2026-10-01T09:00:00Z" }),
            agencyDecision({
              id: "b",
              outcome: "changes_required",
              decided_at: "2026-10-01T10:00:00Z",
            }),
            agencyDecision({
              id: "c",
              outcome: "deferred",
              decided_at: "2026-10-01T11:00:00Z",
            }),
          ],
        }),
      ],
    });
    expect(build(data)[0].state).toBe("new_version_asked");
  });

  it("greys a replaced artboard and offers it no decision", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(STORY, "resize", {
          replaced: true,
          status: "not_relevant",
        }),
      ],
    });
    expect(build(data)[0]).toMatchObject({
      state: "replaced",
      decidable: false,
    });
  });
});

describe("requestProgress", () => {
  it("counts decided artboards and leaves replaced ones out", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(HERO, "craft", { status: "approved" }),
        requestApproval(STORY, "resize", {
          replaced: true,
          status: "not_relevant",
        }),
        requestApproval(FEED, "resize", { status: "changes_required" }),
      ],
    });
    const progress = requestProgress(build(data));
    expect(progress).toEqual({
      decided: 2,
      total: 2,
      approved: 1,
      newVersions: 1,
      complete: true,
    });
    expect(progressLabel(progress)).toBe("2 of 2 decided");
    expect(completionSummary(progress)).toBe(
      "All 2 reviewed · 1 approved · 1 new version asked"
    );
  });

  it("is not complete while anything is undecided", () => {
    const progress = requestProgress(build());
    expect(progress.complete).toBe(false);
    expect(progressLabel(progress)).toBe("0 of 3 decided");
  });
});

describe("approveAllPlan", () => {
  it("approves every undecided artboard except one pinned this visit", () => {
    const plan = approveAllPlan(build(), new Set(["r1"]));
    expect(plan).toEqual({ ids: ["ra_g1", "ra_r2"], skippedWithPins: 1 });
    expect(approveAllLabel(plan)).toBe("Approve 2 · 1 has pins");
    expect(approveAllLabel(approveAllPlan(build(), new Set()))).toBe(
      "Approve all 3"
    );
  });

  it("leaves out what the viewer already answered and what is replaced", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(HERO, "craft", { decisions: [agencyDecision()] }),
        requestApproval(STORY, "resize", {
          replaced: true,
          status: "not_relevant",
        }),
        requestApproval(FEED, "resize"),
      ],
    });
    expect(approveAllPlan(build(data), new Set()).ids).toEqual(["ra_r2"]);
  });
});

describe("nextUndecided", () => {
  it("walks forward from the current artboard and wraps", () => {
    const artboards = build();
    expect(nextUndecided(artboards, "ra_g1")?.id).toBe("ra_r1");
    expect(nextUndecided(artboards, "ra_r2")?.id).toBe("ra_g1");
    expect(nextUndecided(artboards, null)?.id).toBe("ra_g1");
  });

  it("is null when nothing else is undecided", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(HERO, "craft"),
        requestApproval(STORY, "resize", { status: "approved" }),
      ],
    });
    expect(nextUndecided(build(data), "ra_g1")).toBeNull();
  });
});

describe("requestVersionIds", () => {
  it("is every artboard's rendered version", () => {
    expect([...requestVersionIds(requestOf(kvRequest())!)]).toEqual([
      "g1",
      "r1",
      "r2",
    ]);
  });
});
```

- [ ] **Step 2: Run it to watch it fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/requestItems.test.ts
```

Expected: FAIL — module not found.

- [ ] **Step 3: The model**

In `src/components/client-lane/kv/roundItems.ts` line 44 make it `export function findInDocument(`.

Create `src/components/client-lane/kv/requestItems.ts`:

```ts
/**
 * A KV approval request as the client page renders it (spec 2026-10-01
 * §5.1): one card per artboard, each with its own approval. Pure — no
 * React, no api.
 */
import type { RequestView } from "@/lib/client-lane/requests";
import {
  artboardStateOf,
  stateOfOutcome,
  type ArtboardState,
} from "@/lib/client-lane/statusTone";
import type {
  ApprovalDecision,
  ApprovalStatus,
  DecisionOutcome,
} from "@/lib/client-lane/types";
import type { PublicKvResponse } from "@/services/query";
import { KV_SHARE_PHASE_LABEL } from "@/types/kv/share-link";

import { itemLabel, kvItemPart } from "./kvItems";
import { findInDocument, type KvRoundItem } from "./roundItems";

export interface RequestArtboard extends KvRoundItem {
  round: number;
  status: ApprovalStatus;
  replaced: boolean;
  decisions: ApprovalDecision[];
  /** What the card says: the settled verdict, else this viewer's own answer. */
  state: ArtboardState;
  /** Open for a decision: pending and not replaced (a viewer may change theirs). */
  decidable: boolean;
}

/**
 * The viewer's own latest answer, matched by the name they decide under —
 * the public shape has no ids (the same key `latestPerActor` uses). A
 * deferral is request-level, never an artboard answer.
 */
function viewerOutcome(
  decisions: ApprovalDecision[],
  viewerName: string | null
): DecisionOutcome | null {
  if (!viewerName) return null;
  const mine = decisions
    .filter((d) => d.actor === viewerName && d.outcome !== "deferred")
    .sort((a, b) => (a.decided_at ?? "").localeCompare(b.decided_at ?? ""));
  return mine[mine.length - 1]?.outcome ?? null;
}

/**
 * Artwork from each approval's frozen snapshot; an approval without one
 * falls back to the live payload by `version_id`, and one with no artwork
 * anywhere is skipped rather than drawn broken.
 */
export function requestArtboards(
  document: PublicKvResponse,
  view: RequestView,
  viewerName: string | null
): RequestArtboard[] {
  const out: RequestArtboard[] = [];
  for (const approval of view.approvals) {
    const item =
      approval.snapshot ?? findInDocument(document, approval.version_id);
    if (!item) continue;
    const settled = artboardStateOf(approval.status, approval.replaced);
    const mine =
      settled === "undecided"
        ? viewerOutcome(approval.decisions, viewerName)
        : null;
    out.push({
      id: approval.id,
      phase: approval.phase,
      versionId: approval.version_id,
      caption: `${KV_SHARE_PHASE_LABEL[approval.phase]} · ${itemLabel(item)}`,
      item,
      part: kvItemPart(item),
      index: out.length,
      round: approval.round,
      status: approval.status,
      replaced: approval.replaced,
      decisions: approval.decisions,
      state: (mine && stateOfOutcome(mine)) || settled,
      decidable: approval.status === "pending" && !approval.replaced,
    });
  }
  return out;
}

/** The versions this request's pins may sit on. */
export function requestVersionIds(view: RequestView): ReadonlySet<string> {
  return new Set(view.approvals.map((a) => a.version_id));
}

export interface RequestProgress {
  decided: number;
  total: number;
  approved: number;
  newVersions: number;
  complete: boolean;
}

/** "2 of 8 decided" — replaced and withdrawn artboards are not in play. */
export function requestProgress(artboards: RequestArtboard[]): RequestProgress {
  const live = artboards.filter(
    (a) => a.state !== "replaced" && a.state !== "withdrawn"
  );
  const decided = live.filter((a) => a.state !== "undecided").length;
  return {
    decided,
    total: live.length,
    approved: live.filter(
      (a) => a.state === "approved" || a.state === "approved_with_fixes"
    ).length,
    newVersions: live.filter((a) => a.state === "new_version_asked").length,
    complete: live.length > 0 && decided === live.length,
  };
}

export function progressLabel(p: RequestProgress): string {
  return `${p.decided} of ${p.total} decided`;
}

/** "All 8 reviewed · 6 approved · 2 new versions asked" (spec §5.1). */
export function completionSummary(p: RequestProgress): string {
  const parts = [`All ${p.total} reviewed`];
  if (p.approved > 0) parts.push(`${p.approved} approved`);
  if (p.newVersions > 0) {
    parts.push(
      `${p.newVersions} new ${p.newVersions === 1 ? "version" : "versions"} asked`
    );
  }
  return parts.join(" · ");
}

export interface ApproveAllPlan {
  ids: string[];
  skippedWithPins: number;
}

/**
 * Approve all (spec §5.1): every undecided artboard this viewer can decide,
 * except one they pinned this visit — that one keeps its own decision.
 */
export function approveAllPlan(
  artboards: RequestArtboard[],
  pinnedVersions: ReadonlySet<string>
): ApproveAllPlan {
  const open = artboards.filter((a) => a.decidable && a.state === "undecided");
  return {
    ids: open.filter((a) => !pinnedVersions.has(a.versionId)).map((a) => a.id),
    skippedWithPins: open.filter((a) => pinnedVersions.has(a.versionId)).length,
  };
}

/** "Approve all 8" / "Approve 7 · 1 has pins". */
export function approveAllLabel(plan: ApproveAllPlan): string {
  if (plan.skippedWithPins === 0) return `Approve all ${plan.ids.length}`;
  const verb = plan.skippedWithPins === 1 ? "has" : "have";
  return `Approve ${plan.ids.length} · ${plan.skippedWithPins} ${verb} pins`;
}

/** The next undecided artboard after `currentId` in request order, wrapping. */
export function nextUndecided(
  artboards: RequestArtboard[],
  currentId: string | null
): RequestArtboard | null {
  const n = artboards.length;
  const start = artboards.findIndex((a) => a.id === currentId);
  for (let step = 1; step <= n; step++) {
    const a = artboards[(start + step + n) % n];
    if (a.id !== currentId && a.decidable && a.state === "undecided") return a;
  }
  return null;
}
```

- [ ] **Step 4: Run the model test**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/requestItems.test.ts
```

Expected: 12 PASS.

- [ ] **Step 5: Write the failing hero test**

Create `src/components/client-lane/kv/KvRequestHero.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { fireEvent, render, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { requestOf } from "@/lib/client-lane/requests";
import {
  FEED,
  HERO,
  STORY,
  kvRequest,
  requestApproval,
} from "@/lib/client-lane/testFixtures";
import type { ShareLinkKv } from "@/lib/client-lane/types";

import { KvRequestHero, type ArtboardIntent } from "./KvRequestHero";
import { requestArtboards, type RequestArtboard } from "./requestItems";

const body = () => within(document.body);
const artboardsOf = (data: ShareLinkKv = kvRequest()) =>
  requestArtboards(data.document, requestOf(data)!, "Dina");

/** Controlled the way DecisionPage drives it. */
function Harness({
  artboards,
  onDecide,
}: {
  artboards: RequestArtboard[];
  onDecide?: (a: RequestArtboard, intent: ArtboardIntent) => void;
}) {
  const [focusedId, setFocusedId] = useState<string | null>(null);
  return (
    <KvRequestHero
      artboards={artboards}
      pins={[]}
      draft={null}
      activePinId={null}
      focusedId={focusedId}
      onFocusChange={setFocusedId}
      keyboardEnabled
      onPlacePin={() => {}}
      onSelectPin={() => {}}
      onDecide={onDecide}
      busy={false}
    />
  );
}

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
});

describe("KvRequestHero", () => {
  it("shows each card's state and its two quick decisions", () => {
    const onDecide = vi.fn();
    render(<Harness artboards={artboardsOf()} onDecide={onDecide} />);

    expect(body().getByText("No decision yet")).toBeInTheDocument();
    fireEvent.click(body().getByRole("button", { name: "Approve Hero board" }));
    expect(onDecide).toHaveBeenCalledWith(
      expect.objectContaining({ id: "ra_g1" }),
      "approve"
    );
    fireEvent.click(
      body().getByRole("button", {
        name: "Ask for a new version of Hero board",
      })
    );
    expect(onDecide).toHaveBeenLastCalledWith(
      expect.objectContaining({ id: "ra_g1" }),
      "new_version"
    );
  });

  it("greys a replaced artboard and offers it no decision", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(HERO, "craft"),
        requestApproval(STORY, "resize", {
          replaced: true,
          status: "not_relevant",
        }),
        requestApproval(FEED, "resize"),
      ],
    });
    render(<Harness artboards={artboardsOf(data)} onDecide={vi.fn()} />);
    fireEvent.click(body().getByRole("button", { name: "Resize" }));

    expect(body().getByText("Replaced by a newer version")).toBeInTheDocument();
    expect(
      body().queryByRole("button", { name: "Approve IG Story · 1080 × 1920" })
    ).toBeNull();
    expect(
      body().getByRole("button", { name: "Approve IG Feed · 1080 × 1080" })
    ).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Open IG Story · 1080 × 1920" })
        .className
    ).toContain("opacity-50");
  });

  it("never offers the pin layer on a replaced artboard", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(HERO, "craft"),
        requestApproval(STORY, "resize", {
          replaced: true,
          status: "not_relevant",
        }),
      ],
    });
    render(<Harness artboards={artboardsOf(data)} onDecide={vi.fn()} />);
    fireEvent.click(body().getByRole("button", { name: "Resize" }));
    fireEvent.click(
      body().getByRole("button", { name: "Open IG Story · 1080 × 1920" })
    );

    expect(
      document.querySelector("[data-client-lane-pin-layer]")?.className
    ).toContain("pointer-events-none");
  });

  it("offers no quick decisions when the link cannot decide", () => {
    render(<Harness artboards={artboardsOf()} />);
    expect(body().queryByRole("button", { name: /^Approve / })).toBeNull();
  });

  it("opens a card focused, steps, and comes back to the grid", () => {
    render(<Harness artboards={artboardsOf()} onDecide={vi.fn()} />);

    fireEvent.click(body().getByRole("button", { name: "Open Hero board" }));
    expect(body().getByText("Craft · Hero board")).toBeInTheDocument();
    fireEvent.click(body().getByRole("button", { name: "Next item" }));
    expect(
      body().getByText("Resize · IG Story · 1080 × 1920")
    ).toBeInTheDocument();
    fireEvent.click(body().getByRole("button", { name: /All 3 artboards/ }));
    expect(
      body().getByRole("button", { name: "Open IG Story · 1080 × 1920" })
    ).toBeInTheDocument();
  });

  it("opens a one-artboard request straight in the focused view", () => {
    const data = kvRequest({ approvals: [requestApproval(HERO, "craft")] });
    render(<Harness artboards={artboardsOf(data)} onDecide={vi.fn()} />);

    expect(body().getByText("Craft · Hero board")).toBeInTheDocument();
    expect(body().queryByRole("button", { name: /All 1 artboards/ })).toBeNull();
  });
});
```

- [ ] **Step 6: Run it to watch it fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvRequestHero.test.tsx
```

Expected: FAIL — `Cannot find module './KvRequestHero'`.

- [ ] **Step 7: Extend KvPhaseGrid and KvFocusedItem**

In `src/components/client-lane/kv/KvPhaseGrid.tsx`, add `import type { ReactNode } from "react";` and extend `KvGridCard` (after `pinCount?`):

```ts
  /** Beside the caption — a request card's state pill. */
  badge?: ReactNode;
  /** Under the caption — the card's own controls (✓ / ✎). Siblings of the
   *  open button, never inside it, so each keeps its own name. */
  actions?: ReactNode;
  /** Greyed: shown, never acted on (a replaced artboard). */
  muted?: boolean;
```

Add a prop to `KvPhaseGrid`:

```ts
  /** Columns on a phone: 2 (galleries) or 1 (a request, spec §5.1). */
  columns?: 1 | 2;
```

(default `columns = 2` in the destructuring). The grid `div` (line 74) becomes:

```tsx
        <div
          className={
            columns === 1
              ? "grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3"
              : "grid grid-cols-2 gap-4 sm:grid-cols-3"
          }
        >
```

The card button's className (line 81) gains `${card.muted ? "opacity-50" : ""}`, and the `figcaption` (lines 96-105) becomes:

```tsx
              <figcaption className="mt-1.5 flex flex-col gap-1.5">
                <span className="flex min-w-0 items-center gap-2">
                  <span className="truncate font-geist text-textXs text-text-inverse-subtle">
                    {card.caption}
                  </span>
                  {card.item.kind === "board" && card.item.is_master && (
                    <span className="rounded-full border border-white/15 px-1.5 py-px font-geist text-textXs uppercase tracking-wide text-text-inverse-subtlest">
                      Master
                    </span>
                  )}
                  {card.badge}
                </span>
                {card.actions}
              </figcaption>
```

In `src/components/client-lane/kv/KvFocusedItem.tsx` add to the props `noun?: string;` (doc: `/** What "All n …" counts — "items" (rounds) or "artboards" (requests). */`), destructure `noun = "items"`, and line 97 becomes `All {total} {noun}`.

- [ ] **Step 8: The hero**

Create `src/components/client-lane/kv/KvRequestHero.tsx`:

```tsx
"use client";

import { Check, PencilSimple } from "@phosphor-icons/react";
import { useCallback, useMemo, useState } from "react";

import { Button } from "@/components/frndos/v2";
import { trackClientGalleryItemOpened } from "@/lib/analytics/client-lane-events";
import type { PagePin } from "@/lib/client-lane/pins";
import type { KvSharePhase } from "@/types/kv/share-link";

import { ArtboardStatePill } from "../StatusPill";
import { KvFocusedItem } from "./KvFocusedItem";
import { KvPhaseGrid, type KvGridCard, type KvGridPhase } from "./KvPhaseGrid";
import { itemLabel } from "./kvItems";
import type { RequestArtboard } from "./requestItems";

export type ArtboardIntent = "approve" | "new_version";

export interface KvRequestHeroProps {
  /** The request's artboards in request order (never empty). */
  artboards: RequestArtboard[];
  /** Every pin on the request, numbered request-wide. */
  pins: PagePin[];
  draft: { version: string; x: number; y: number } | null;
  activePinId: string | null;
  /** Controlled: the artboard in the focused view; `null` = the grid. */
  focusedId: string | null;
  onFocusChange: (id: string | null) => void;
  /** False while a sheet is open, so ←/→ in a note never changes artboard. */
  keyboardEnabled: boolean;
  /** Absent → no pins. Never offered on a replaced artboard. */
  onPlacePin?: (artboard: RequestArtboard, x: number, y: number) => void;
  onSelectPin: (id: string | null) => void;
  /** Absent → no ✓ / ✎ on the cards (closed request, read-only link). */
  onDecide?: (artboard: RequestArtboard, intent: ArtboardIntent) => void;
  busy: boolean;
}

/**
 * A KV request on the client page (spec 2026-10-01 §5.1): artboards grouped
 * by phase, each card with its state and quick ✓ (approve) / ✎ (request a
 * new version); a tapped card opens the focused view with its pins. A
 * one-artboard request opens straight in the focused view.
 */
export function KvRequestHero({
  artboards,
  pins,
  draft,
  activePinId,
  focusedId,
  onFocusChange,
  keyboardEnabled,
  onPlacePin,
  onSelectPin,
  onDecide,
  busy,
}: KvRequestHeroProps) {
  const single = artboards.length === 1;
  const focused = single
    ? artboards[0]
    : (artboards.find((a) => a.id === focusedId) ?? null);
  const [activePhase, setActivePhase] = useState<KvSharePhase | null>(
    artboards[0]?.phase ?? null
  );

  const phases = useMemo<KvGridPhase[]>(() => {
    const count = new Map<string, number>();
    for (const p of pins) count.set(p.version, (count.get(p.version) ?? 0) + 1);
    const out: KvGridPhase[] = [];
    for (const a of artboards) {
      let group = out.find((g) => g.phase === a.phase);
      if (!group) {
        group = { phase: a.phase, cards: [] };
        out.push(group);
      }
      const caption = itemLabel(a.item);
      group.cards.push({
        key: a.id,
        item: a.item,
        caption,
        pinCount: count.get(a.versionId) ?? 0,
        muted: a.replaced,
        badge: <ArtboardStatePill state={a.state} />,
        actions:
          onDecide && a.decidable ? (
            <span className="flex items-center gap-1.5">
              <Button
                variant="icon"
                size="medium"
                aria-label={`Approve ${caption}`}
                disabled={busy}
                onClick={() => onDecide(a, "approve")}
              >
                <Check size={16} weight="bold" />
              </Button>
              <Button
                variant="icon"
                size="medium"
                aria-label={`Ask for a new version of ${caption}`}
                disabled={busy}
                onClick={() => onDecide(a, "new_version")}
              >
                <PencilSimple size={16} />
              </Button>
            </span>
          ) : undefined,
      });
    }
    return out;
  }, [artboards, pins, onDecide, busy]);

  const open = (card: KvGridCard) => {
    const a = artboards.find((x) => x.id === card.key);
    if (!a) return;
    trackClientGalleryItemOpened({ phase: a.phase, index: a.index });
    onFocusChange(a.id);
  };

  const step = useCallback(
    (delta: 1 | -1) => {
      if (!focused) return;
      const at = artboards.indexOf(focused);
      const next = artboards[(at + delta + artboards.length) % artboards.length];
      setActivePhase(next.phase);
      onFocusChange(next.id);
    },
    [focused, artboards, onFocusChange]
  );

  const back = useCallback(() => {
    if (focused) setActivePhase(focused.phase);
    onFocusChange(null);
  }, [focused, onFocusChange]);

  if (focused) {
    return (
      <KvFocusedItem
        entry={focused}
        total={artboards.length}
        noun="artboards"
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
          onPlacePin && !focused.replaced
            ? (x, y) => onPlacePin(focused, x, y)
            : undefined
        }
        onSelectPin={onSelectPin}
      />
    );
  }

  return (
    <section
      aria-label="Artboards in this request"
      className="flex flex-col gap-3"
    >
      <p className="font-geist text-textXs text-text-inverse-subtlest">
        Tap an artboard to see it large
        {onPlacePin ? " and pin a note on it" : ""}.
      </p>
      <KvPhaseGrid
        phases={phases}
        activePhase={activePhase}
        onPhaseChange={setActivePhase}
        onOpen={open}
        columns={1}
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

- [ ] **Step 9: Run the hero test and the neighbours**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvRequestHero.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvRoundHero.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/KvLinkGallery.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/kv/roundItems.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.test.tsx
```

Expected: 6 PASS; the four round/gallery suites unchanged from Task 0.

- [ ] **Step 10: Mutation checks**

1. In `requestArtboards`, set `state: settled` (ignore `mine`) → "reads the viewer's own answer on a still-pending artboard" FAILS. Restore.
2. In `approveAllPlan`, drop the `!pinnedVersions.has(...)` filter on `ids` → "approves every undecided artboard except one pinned this visit" FAILS. Restore.
3. In `requestProgress`, count `artboards` instead of `live` → "counts decided artboards and leaves replaced ones out" FAILS. Restore.
4. In `KvRequestHero`, pass `onPlacePin` to `KvFocusedItem` regardless of `focused.replaced` → "never offers the pin layer on a replaced artboard" FAILS. Restore.
5. Drop `a.decidable &&` from the `actions` condition → "greys a replaced artboard and offers it no decision" FAILS. Restore.

- [ ] **Step 11: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/client-lane/kv/roundItems.ts src/components/client-lane/kv/requestItems.ts src/components/client-lane/kv/requestItems.test.ts src/components/client-lane/kv/KvPhaseGrid.tsx src/components/client-lane/kv/KvFocusedItem.tsx src/components/client-lane/kv/KvRequestHero.tsx src/components/client-lane/kv/KvRequestHero.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-lane/kv/"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: nothing; 895.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/client-lane/kv && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): KV request model and hero — a state and quick decisions per artboard

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: RequestRail + the new-version note sheet

The right column (spec §5.1): the agency message, `2 of 8 decided`, `Decide by …`, Approve all (`Approve 7 · 1 has pins`) and I need more time; when focused, that artboard's pins, `3 pins included`, Approve / Request new version and Next undecided; the completion summary; and the "What should change?" sheet (required, ≤ 2000).

**Files:**
- Create: `src/components/client-lane/RequestProgressBar.tsx` (v1 ProgressBar only), `src/components/client-lane/RequestRail.tsx` (v2), `src/components/client-lane/sheets/NewVersionNoteSheet.tsx` (v2), `src/components/client-lane/RequestRail.test.tsx`

**Interfaces:**
- Consumes: `RequestArtboard`, `RequestProgress`, `ApproveAllPlan`, `approveAllLabel`, `progressLabel`, `completionSummary`, `ArtboardIntent` (Task 7); `ArtboardStatePill` (Task 3); `PublicRequest` (Task 1); the client-lane `Sheet`.
- Produces:
  - `RequestOverview({ request; workspaceName; progress; footer?: ReactNode; className? })`
  - `RequestOutcomeBanner({ request; progress })` — withdrawn line, or the completion summary once complete / settled, else nothing
  - `FocusedArtboardPanel({ artboard; includedPins: number; children? })`
  - `RequestActionBar({ focused: RequestArtboard | null; plan; nextId: string | null; busy; onApproveAll(); onMoreTime(); onDecide(a, intent); onNext() })` — fixed to the bottom on phones, in the rail from `lg`
  - `NewVersionNoteSheet({ open; caption: string; busy; onSubmit(note: string); onClose() })`

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/RequestRail.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { fireEvent, render, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { requestOf } from "@/lib/client-lane/requests";
import { kvRequest, publicRequest } from "@/lib/client-lane/testFixtures";

import {
  FocusedArtboardPanel,
  RequestActionBar,
  RequestOutcomeBanner,
  RequestOverview,
} from "./RequestRail";
import {
  approveAllPlan,
  requestArtboards,
  requestProgress,
} from "./kv/requestItems";
import { NewVersionNoteSheet } from "./sheets/NewVersionNoteSheet";

const body = () => within(document.body);
const artboards = requestArtboards(
  kvRequest().document,
  requestOf(kvRequest())!,
  "Dina"
);
const progress = requestProgress(artboards);
const DONE = {
  decided: 3,
  total: 3,
  approved: 2,
  newVersions: 1,
  complete: true,
};

describe("RequestOverview", () => {
  it("says what the team asked, how far the client is and by when", () => {
    render(
      <RequestOverview
        request={publicRequest({
          approvers: [
            { name: "Dina", decided: false },
            { name: "Bayu", decided: true },
          ],
        })}
        workspaceName="Alva"
        progress={progress}
      />
    );
    expect(body().getByText("From Alva")).toBeInTheDocument();
    expect(body().getByText("Three artboards ready")).toBeInTheDocument();
    expect(body().getByText("0 of 3 decided")).toBeInTheDocument();
    expect(body().getByRole("progressbar")).toBeInTheDocument();
    expect(body().getByText(/^Decide by /)).toBeInTheDocument();
    expect(body().getByText("Waiting on Dina")).toBeInTheDocument();
  });

  it("shows the client's own 'more time' line", () => {
    render(
      <RequestOverview
        request={publicRequest({
          deferred_until: "2026-10-08",
          deferred_note: "Travelling",
        })}
        workspaceName="Alva"
        progress={progress}
      />
    );
    expect(
      body().getByText(/^More time asked for until .+ — “Travelling”$/)
    ).toBeInTheDocument();
  });
});

describe("RequestOutcomeBanner", () => {
  it("says nothing while artboards are undecided", () => {
    const { container } = render(
      <RequestOutcomeBanner request={publicRequest()} progress={progress} />
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("sums up a finished review", () => {
    render(
      <RequestOutcomeBanner
        request={publicRequest({ status: "changes_required" })}
        progress={DONE}
      />
    );
    expect(body().getByRole("status")).toHaveTextContent(
      "All 3 reviewed · 2 approved · 1 new version asked"
    );
  });

  it("says a withdrawn request needs nothing more", () => {
    render(
      <RequestOutcomeBanner
        request={publicRequest({ status: "not_relevant" })}
        progress={progress}
      />
    );
    expect(body().getByRole("status")).toHaveTextContent(
      /withdrawn by the team/
    );
  });
});

describe("RequestActionBar", () => {
  const actions = () => ({
    onApproveAll: vi.fn(),
    onMoreTime: vi.fn(),
    onDecide: vi.fn(),
    onNext: vi.fn(),
  });

  it("approves all but the pinned artboard from the grid", () => {
    const a = actions();
    render(
      <RequestActionBar
        focused={null}
        plan={approveAllPlan(artboards, new Set(["r1"]))}
        nextId="ra_g1"
        busy={false}
        {...a}
      />
    );
    fireEvent.click(
      body().getByRole("button", { name: "Approve 2 · 1 has pins" })
    );
    expect(a.onApproveAll).toHaveBeenCalled();
    fireEvent.click(body().getByRole("button", { name: "I need more time" }));
    expect(a.onMoreTime).toHaveBeenCalled();
  });

  it("decides the focused artboard and walks to the next undecided", () => {
    const a = actions();
    render(
      <RequestActionBar
        focused={artboards[1]}
        plan={approveAllPlan(artboards, new Set())}
        nextId="ra_r2"
        busy={false}
        {...a}
      />
    );
    fireEvent.click(body().getByRole("button", { name: "Approve" }));
    expect(a.onDecide).toHaveBeenCalledWith(artboards[1], "approve");
    fireEvent.click(
      body().getByRole("button", { name: "Request new version" })
    );
    expect(a.onDecide).toHaveBeenLastCalledWith(artboards[1], "new_version");
    fireEvent.click(body().getByRole("button", { name: "Next undecided" }));
    expect(a.onNext).toHaveBeenCalled();
    expect(body().queryByRole("button", { name: /^Approve all/ })).toBeNull();
  });

  it("disables Next undecided when nothing else is open", () => {
    render(
      <RequestActionBar
        focused={artboards[0]}
        plan={approveAllPlan(artboards, new Set())}
        nextId={null}
        busy={false}
        {...actions()}
      />
    );
    expect(
      body().getByRole("button", { name: "Next undecided" })
    ).toBeDisabled();
  });
});

describe("FocusedArtboardPanel", () => {
  it("counts the pins that ride on the decision", () => {
    render(<FocusedArtboardPanel artboard={artboards[0]} includedPins={3} />);
    expect(body().getByText("3 pins included")).toBeInTheDocument();
    expect(body().getByText("No decision yet")).toBeInTheDocument();
  });
});

describe("NewVersionNoteSheet", () => {
  it("needs a note before it asks for a new version", () => {
    const onSubmit = vi.fn();
    render(
      <NewVersionNoteSheet
        open
        caption="Craft · Hero board"
        busy={false}
        onSubmit={onSubmit}
        onClose={() => {}}
      />
    );
    fireEvent.click(
      body().getByRole("button", { name: "Ask for a new version" })
    );
    expect(body().getByRole("alert")).toHaveTextContent(
      "Say what should change"
    );
    expect(onSubmit).not.toHaveBeenCalled();

    fireEvent.change(
      body().getByRole("textbox", { name: "What should change?" }),
      { target: { value: "  Logo smaller  " } }
    );
    fireEvent.click(
      body().getByRole("button", { name: "Ask for a new version" })
    );
    expect(onSubmit).toHaveBeenCalledWith("Logo smaller");
  });
});
```

- [ ] **Step 2: Run it to watch it fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/RequestRail.test.tsx
```

Expected: FAIL — modules not found.

- [ ] **Step 3: Implement the three files**

Create `src/components/client-lane/RequestProgressBar.tsx`:

```tsx
"use client";

import { ProgressBar } from "@/components/frndos/ProgressBar";

/** "2 of 8 decided" as a bar — the frndOS v1 `ProgressBar`, alone in its
 *  file so the v2 rail never imports v1 (spec §11.2). */
export function RequestProgressBar({
  decided,
  total,
}: {
  decided: number;
  total: number;
}) {
  return (
    <ProgressBar
      value={decided}
      max={total}
      size="sm"
      ariaLabel={`${decided} of ${total} decided`}
    />
  );
}
```

Create `src/components/client-lane/RequestRail.tsx`:

```tsx
"use client";

import clsx from "clsx";
import type { ReactNode } from "react";

import { Button } from "@/components/frndos/v2";
import { deferralDate } from "@/lib/client-lane/format";
import type { PublicRequest } from "@/lib/client-lane/types";

import { RequestProgressBar } from "./RequestProgressBar";
import { ArtboardStatePill } from "./StatusPill";
import type { ArtboardIntent } from "./kv/KvRequestHero";
import {
  approveAllLabel,
  completionSummary,
  progressLabel,
  type ApproveAllPlan,
  type RequestArtboard,
  type RequestProgress,
} from "./kv/requestItems";

/**
 * The request link's right column (spec 2026-10-01 §5.1). The page is
 * dark-scoped (`data-theme-scope="dark"` + the client-lane token reset), so
 * the inverse tokens read as the Midnight values under any viewer theme.
 */
const RAIL_CARD = "rounded-2xl border border-white/10 bg-white/5 p-4 font-geist";
const RAIL_EYEBROW =
  "font-geist text-textXsMedium uppercase tracking-wider text-text-inverse-subtlest";

export function RequestOverview({
  request,
  workspaceName,
  progress,
  footer,
  className,
}: {
  request: PublicRequest;
  workspaceName: string;
  progress: RequestProgress;
  /** The approver hint ("Email me my link"), when it applies. */
  footer?: ReactNode;
  className?: string;
}) {
  const waiting = request.approvers
    .filter((a) => !a.decided)
    .map((a) => a.name);
  return (
    <section
      aria-label={`Request ${request.number}`}
      className={clsx(RAIL_CARD, "flex flex-col gap-3", className)}
    >
      {request.message && (
        <div>
          <h2 className={RAIL_EYEBROW}>From {workspaceName}</h2>
          <p className="mt-1.5 whitespace-pre-wrap text-textSm text-text-inverse">
            {request.message}
          </p>
        </div>
      )}
      <div className="flex flex-col gap-2">
        <p className="text-textSmMedium text-text-inverse">
          {progressLabel(progress)}
        </p>
        <RequestProgressBar decided={progress.decided} total={progress.total} />
        {request.decide_by && (
          <p className="text-textXs text-text-inverse-subtle">
            Decide by {deferralDate(request.decide_by)}
          </p>
        )}
        {request.deferred_until && (
          <p className="text-textXs text-text-inverse-subtle">
            More time asked for until {deferralDate(request.deferred_until)}
            {request.deferred_note ? ` — “${request.deferred_note}”` : ""}
          </p>
        )}
        {request.status === "pending" && waiting.length > 0 && (
          <p className="text-textXs text-text-inverse-subtlest">
            Waiting on {waiting.join(", ")}
          </p>
        )}
      </div>
      {footer}
    </section>
  );
}

/**
 * A withdrawn request says so; a finished review (every artboard answered,
 * or the request settled) says how it went. Nothing while work is open.
 */
export function RequestOutcomeBanner({
  request,
  progress,
}: {
  request: PublicRequest;
  progress: RequestProgress;
}) {
  if (request.status === "not_relevant") {
    return (
      <p role="status" className={clsx(RAIL_CARD, "text-textSm text-text-inverse-subtle")}>
        This request was withdrawn by the team. Nothing more is needed from you.
      </p>
    );
  }
  if (progress.total === 0) return null;
  if (!progress.complete && request.status === "pending") return null;
  return (
    <div role="status" className={clsx(RAIL_CARD, "flex flex-col gap-1")}>
      <p className="text-textSmMedium text-text-inverse">
        {completionSummary(progress)}
      </p>
      <p className="text-textXs text-text-inverse-subtle">
        The team has your answers.
      </p>
    </div>
  );
}

/** The focused artboard in the rail: its state, its pin threads, and how
 *  many of this visit's pins ride on the decision. */
export function FocusedArtboardPanel({
  artboard,
  includedPins,
  children,
}: {
  artboard: RequestArtboard;
  includedPins: number;
  /** Its `PinList`. */
  children?: ReactNode;
}) {
  return (
    <section
      aria-label={artboard.caption}
      className={clsx(RAIL_CARD, "flex flex-col gap-3")}
    >
      <div className="flex items-center justify-between gap-2">
        <p className="min-w-0 truncate text-textSmMedium text-text-inverse">
          {artboard.caption}
        </p>
        <ArtboardStatePill state={artboard.state} />
      </div>
      {children}
      {artboard.decidable && (
        <p className="text-textXs text-text-inverse-subtle">
          {includedPins > 0
            ? `${includedPins} ${includedPins === 1 ? "pin" : "pins"} included`
            : "Tap the artwork to pin a note — it rides on your decision."}
        </p>
      )}
    </section>
  );
}

/**
 * The decision controls. Phone: fixed to the bottom of the screen (spec
 * §5.1 "sticky Approve all", "bottom bar of Approve / Request new version");
 * from `lg` it sits in the rail.
 */
export function RequestActionBar({
  focused,
  plan,
  nextId,
  busy,
  onApproveAll,
  onMoreTime,
  onDecide,
  onNext,
}: {
  focused: RequestArtboard | null;
  plan: ApproveAllPlan;
  nextId: string | null;
  busy: boolean;
  onApproveAll: () => void;
  onMoreTime: () => void;
  onDecide: (artboard: RequestArtboard, intent: ArtboardIntent) => void;
  onNext: () => void;
}) {
  return (
    <div className="fixed inset-x-0 bottom-0 z-30 flex flex-col gap-2 border-t border-white/10 bg-surface-default px-4 pb-[max(env(safe-area-inset-bottom),1rem)] pt-3 lg:static lg:z-auto lg:rounded-2xl lg:border lg:bg-white/5 lg:p-4">
      {focused ? (
        <>
          {focused.decidable && (
            <div className="grid grid-cols-2 gap-2">
              <Button
                size="large"
                disabled={busy}
                onClick={() => onDecide(focused, "approve")}
              >
                Approve
              </Button>
              <Button
                variant="secondary"
                size="large"
                disabled={busy}
                onClick={() => onDecide(focused, "new_version")}
              >
                Request new version
              </Button>
            </div>
          )}
          <Button
            variant="text"
            size="medium"
            disabled={busy || nextId === null}
            onClick={onNext}
          >
            Next undecided
          </Button>
        </>
      ) : (
        <>
          {plan.ids.length > 0 && (
            <Button
              size="large"
              className="w-full"
              disabled={busy}
              onClick={onApproveAll}
            >
              {approveAllLabel(plan)}
            </Button>
          )}
          <Button
            variant="text"
            size="medium"
            disabled={busy}
            onClick={onMoreTime}
          >
            I need more time
          </Button>
        </>
      )}
    </div>
  );
}
```

Create `src/components/client-lane/sheets/NewVersionNoteSheet.tsx`:

```tsx
"use client";

import { useState } from "react";

import { AutoGrowTextarea, Button } from "@/components/frndos/v2";

import { Sheet } from "../Sheet";

const MAX_NOTE = 2000;
const NOTE_FIELD =
  "rounded-xl border border-white/10 bg-white/5 px-3 py-3 font-geist text-textSm text-text-inverse outline-none transition-all duration-200 ease-out placeholder:text-text-inverse-subtlest focus:border-white/20 focus:ring-0 focus-visible:ring-2 focus-visible:ring-white/40";

/**
 * "Request new version" on an artboard with no pins from this visit (spec
 * §5.1): the note is required (≤ 2000 chars) — the api refuses a
 * `changes_required` with neither pins nor a note (`note_required`).
 */
export function NewVersionNoteSheet({
  open,
  caption,
  busy,
  onSubmit,
  onClose,
}: {
  open: boolean;
  /** "Resize · IG Story · 1080 × 1920" — which artboard this is about. */
  caption: string;
  busy: boolean;
  onSubmit: (note: string) => void;
  onClose: () => void;
}) {
  const [note, setNote] = useState("");
  const [touched, setTouched] = useState(false);
  const trimmed = note.trim();
  const ok = trimmed.length > 0 && trimmed.length <= MAX_NOTE;

  return (
    <Sheet
      open={open}
      title="What should change?"
      onClose={onClose}
      dismissible={!busy}
    >
      <form
        className="flex flex-col gap-3 pb-2 font-geist"
        onSubmit={(e) => {
          e.preventDefault();
          setTouched(true);
          if (!ok || busy) return;
          onSubmit(trimmed);
        }}
      >
        <p className="text-textSm text-text-inverse-subtle">
          {caption} — say what the next version should fix.
        </p>
        <AutoGrowTextarea
          autoFocus
          rows={4}
          maxLength={MAX_NOTE}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          aria-label="What should change?"
          placeholder="Move the price tag left so it clears the pack. Rest is good."
          className={NOTE_FIELD}
        />
        {touched && !ok && (
          <p role="alert" className="text-textXs text-negative-400">
            Say what should change — the team needs the note.
          </p>
        )}
        <Button type="submit" size="large" loading={busy} disabled={busy}>
          Ask for a new version
        </Button>
      </form>
    </Sheet>
  );
}
```

- [ ] **Step 4: Run the test**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/RequestRail.test.tsx
```

Expected: 10 PASS.

- [ ] **Step 5: Mutation checks**

1. In `RequestOutcomeBanner`, drop `if (!progress.complete && request.status === "pending") return null;` → "says nothing while artboards are undecided" FAILS. Restore.
2. In `RequestActionBar`, render Approve all whenever `focused` is null even with `plan.ids` empty AND show it in focused mode too (move it above the `focused ?` branch) → "decides the focused artboard…" FAILS (Approve all present). Restore.
3. In `NewVersionNoteSheet`, submit `note` instead of `trimmed` → "needs a note before…" FAILS. Restore.

- [ ] **Step 6: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/client-lane/RequestProgressBar.tsx src/components/client-lane/RequestRail.tsx src/components/client-lane/RequestRail.test.tsx src/components/client-lane/sheets/NewVersionNoteSheet.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "RequestRail|RequestProgressBar|NewVersionNoteSheet"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"; /usr/bin/grep -nE -- "-\[[0-9]+px\]|text-white\b|text-gray-|bg-black" src/components/client-lane/RequestRail.tsx src/components/client-lane/sheets/NewVersionNoteSheet.tsx
```

Expected: nothing; 895; nothing.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/client-lane/RequestProgressBar.tsx src/components/client-lane/RequestRail.tsx src/components/client-lane/RequestRail.test.tsx src/components/client-lane/sheets/NewVersionNoteSheet.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): request rail — progress, deadline, Approve all, focused decisions, note sheet

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: DecisionPage — the request branch

`DecisionPage` branches on `requestOf(data)` (spec §5.1). A request link renders `KvRequestHero` + the rail and posts every decision with `approval_ids`; deck, plan, KV view and legacy KV round links keep the existing code path. Kept for request links: the advisory card (per request), the approver hint, `NameGateSheet` on the first write, comment threads and replies, the dark-scope token reset. Not rendered for request links: `HowBigSheet`, `DecisionBar`, `VersionStrip`, `TerminalBanner`.

**Files:**
- Modify: `src/components/client-lane/DecisionPage.tsx`, `src/lib/analytics/client-lane-events.ts`
- Create: `src/components/client-lane/DecisionPage.request.test.tsx`, `src/components/client-lane/DecisionPage.regression.test.tsx`

**Interfaces:**
- Consumes: everything from Tasks 1, 7, 8 (`requestOf`, `plural`, `postRequestDecision`, `RequestDecisionDraft`, `readDraft<T>`, `requestArtboards`, `requestVersionIds`, `requestProgress`, `approveAllPlan`, `nextUndecided`, `KvRequestHero`, `ArtboardIntent`, `RequestOverview`, `RequestOutcomeBanner`, `FocusedArtboardPanel`, `RequestActionBar`, `NewVersionNoteSheet`).
- Produces: analytics `ArtboardDecisionSource = "card" | "focused"`, `trackClientArtboardDecided({ outcome, pin_count, source })`, `trackClientApproveAll({ count, skipped_with_pins })`, `trackClientRequestDecisionFailed({ reason, http_status })` (event `client_lane.client_decision_failed`), `trackClientRequestCompleted({ artboard_count, changes_count })`.

- [ ] **Step 1: Write the failing page tests**

Create `src/components/client-lane/DecisionPage.request.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  FEED,
  HERO,
  STORY,
  agencyDecision,
  kvRequest,
  pinComment,
  publicRequest,
  requestApproval,
} from "@/lib/client-lane/testFixtures";
import type {
  ApprovalStatus,
  PublicComment,
  RequestDecisionInput,
  ShareLinkKv,
} from "@/lib/client-lane/types";
import { axiosPublic } from "@/services/axios";

import { DecisionPage } from "./DecisionPage";

const body = () => within(document.body);
const DECISION_URL = "public/share-links/tok/decision";

/**
 * The public api edge — spied, never vi.mock'ed. The decision stub keeps the
 * request's state between calls, so a page that makes several decisions
 * sees each one land. `/s/session` hands back a lane code (Dina's personal
 * link), so no name gate.
 */
function stubApi(rows: PublicComment[] = [], start: ShareLinkKv = kvRequest()) {
  vi.spyOn(globalThis, "fetch").mockImplementation(
    (async () =>
      new Response(JSON.stringify({ code: "abcdefghijklmnop" }), {
        status: 200,
      })) as unknown as typeof fetch
  );
  const get = vi.spyOn(axiosPublic, "get").mockImplementation((async (
    url: string
  ) => {
    if (url === "public/share-links/tok/comments")
      return { data: { data: rows } };
    // `refresh()` after a stale-request refusal re-reads the link.
    if (url === "public/share-links/tok") return { data: { data: start } };
    throw new Error(`unexpected GET ${url}`);
  }) as never);
  let approvals = start.approvals ?? [];
  const post = vi.spyOn(axiosPublic, "post").mockImplementation((async (
    url: string,
    input: Record<string, unknown>
  ) => {
    if (url === "public/share-links/tok/comments") {
      const anchor = input.anchor as PublicComment["anchor"];
      return {
        data: {
          data: pinComment("c_new", anchor?.id ?? "", "2026-10-01T12:00:00Z", {
            anchor,
            body: String(input.body),
          }),
        },
      };
    }
    if (url === DECISION_URL) {
      const body = input as unknown as RequestDecisionInput;
      if (body.outcome === "deferred") {
        return {
          data: {
            data: {
              results: [],
              request: {
                ...start.request!,
                deferred_until: body.deferred_until ?? null,
              },
              approvals,
            },
          },
        };
      }
      const ids = body.approval_ids ?? [];
      const stored = (
        body.outcome === "approved" && (body.pins?.length ?? 0) > 0
          ? "approved_with_changes"
          : body.outcome
      ) as "approved" | "approved_with_changes" | "changes_required";
      const decision = (id: string) =>
        agencyDecision({ id: `d_${id}`, outcome: stored });
      approvals = approvals.map((a) =>
        ids.includes(a.id)
          ? {
              ...a,
              status: stored as ApprovalStatus,
              decisions: [...a.decisions, decision(a.id)],
            }
          : a
      );
      const live = approvals.filter((a) => !a.replaced);
      const status: ApprovalStatus = live.some((a) => a.status === "pending")
        ? "pending"
        : live.some((a) => a.status === "changes_required")
          ? "changes_required"
          : "approved";
      return {
        data: {
          data: {
            results: ids.map((id) => ({
              approval_id: id,
              result: "decided",
              decision: decision(id),
            })),
            request: { ...start.request!, status },
            approvals,
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

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function renderPage(data: ShareLinkKv = kvRequest()) {
  return render(<DecisionPage token="tok" initialData={data} />, {
    wrapper: QueryWrapper,
  });
}

const decisionBodies = (post: ReturnType<typeof stubApi>["post"]) =>
  post.mock.calls
    .filter((c) => c[0] === DECISION_URL)
    .map((c) => c[1] as Record<string, unknown>);

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
  // The caption shows twice once focused: under the artwork and in the rail.
  await body().findAllByText("Resize · IG Story · 1080 × 1920");
}

/** Place and post a pin on the focused artboard. */
async function pinIt(user: ReturnType<typeof userEvent.setup>) {
  tapPinLayer(50, 50);
  await body().findByRole("dialog", { name: /pin 1 · v1/ });
  await user.type(
    body().getByRole("textbox", { name: /Price tag covers/ }),
    "Crop tighter"
  );
  await user.click(body().getByRole("button", { name: "Post" }));
  await waitFor(() =>
    expect(body().queryByRole("dialog", { name: /pin 1 · v1/ })).toBeNull()
  );
}

beforeEach(() => {
  vi.restoreAllMocks();
  window.localStorage.clear();
  window.sessionStorage.clear();
});

describe("DecisionPage — a request link", () => {
  it("shows each artboard's state and the request's progress, not the round bar", async () => {
    stubApi();
    renderPage();

    expect(
      await body().findByRole("button", { name: "Approve Hero board" })
    ).toBeInTheDocument();
    expect(body().getByRole("heading", { level: 1 })).toHaveTextContent(
      "Ramadan hero · Request 2 · 3 artboards"
    );
    expect(body().getByText("0 of 3 decided")).toBeInTheDocument();
    expect(body().getByText("Three artboards ready")).toBeInTheDocument();
    expect(body().getByText(/^Decide by /)).toBeInTheDocument();
    expect(body().getByText("No decision yet")).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Approve all 3" })
    ).toBeInTheDocument();
    expect(body().queryByRole("button", { name: "Request changes" })).toBeNull();
  });

  it("saves a card's approval the moment it is made", async () => {
    const { post, capture } = stubApi();
    const user = userEvent.setup();
    renderPage();

    await user.click(
      await body().findByRole("button", { name: "Approve Hero board" })
    );

    expect(await body().findByText("1 of 3 decided")).toBeInTheDocument();
    expect(decisionBodies(post)[0]).toEqual({
      approval_ids: ["ra_g1"],
      outcome: "approved",
    });
    expect(body().getByText("Approved")).toBeInTheDocument();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.client_artboard_decided",
      expect.objectContaining({
        outcome: "approved",
        pin_count: 0,
        source: "card",
      })
    );
  });

  it("asks what should change when a new version is asked without pins", async () => {
    const { post } = stubApi();
    const user = userEvent.setup();
    renderPage();

    await user.click(
      await body().findByRole("button", {
        name: "Ask for a new version of Hero board",
      })
    );
    await body().findByRole("dialog", { name: "What should change?" });
    await user.click(
      body().getByRole("button", { name: "Ask for a new version" })
    );
    expect(body().getByRole("alert")).toHaveTextContent(
      "Say what should change"
    );
    expect(decisionBodies(post)).toHaveLength(0);

    await user.type(
      body().getByRole("textbox", { name: "What should change?" }),
      "Logo smaller"
    );
    await user.click(
      body().getByRole("button", { name: "Ask for a new version" })
    );

    expect(await body().findByText("New version asked")).toBeInTheDocument();
    expect(decisionBodies(post)[0]).toEqual({
      approval_ids: ["ra_g1"],
      outcome: "changes_required",
      note: "Logo smaller",
    });
  });

  it("asks for a new version with this artboard's pins, at once", async () => {
    const { post, capture } = stubApi();
    const user = userEvent.setup();
    renderPage();

    await openStory(user);
    await pinIt(user);
    expect(await body().findByText("1 pin included")).toBeInTheDocument();
    await user.click(
      body().getByRole("button", { name: "Request new version" })
    );

    await waitFor(() =>
      expect(decisionBodies(post)[0]).toEqual({
        approval_ids: ["ra_r1"],
        outcome: "changes_required",
        pins: ["c_new"],
      })
    );
    expect(
      body().queryByRole("dialog", { name: "What should change?" })
    ).toBeNull();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.client_artboard_decided",
      expect.objectContaining({ pin_count: 1, source: "focused" })
    );
  });

  it("skips the pinned artboard in Approve all", async () => {
    const { post, capture } = stubApi();
    const user = userEvent.setup();
    renderPage();

    await openStory(user);
    await pinIt(user);
    await user.click(body().getByRole("button", { name: /All 3 artboards/ }));
    await user.click(
      await body().findByRole("button", { name: "Approve 2 · 1 has pins" })
    );

    await waitFor(() =>
      expect(decisionBodies(post)[0]).toEqual({
        approval_ids: ["ra_g1", "ra_r2"],
        outcome: "approved",
      })
    );
    expect(capture).toHaveBeenCalledWith(
      "client_lane.client_approve_all",
      expect.objectContaining({ count: 2, skipped_with_pins: 1 })
    );
  });

  it("leaves a replaced artboard out of progress and Approve all", async () => {
    stubApi();
    const user = userEvent.setup();
    renderPage(
      kvRequest({
        approvals: [
          requestApproval(HERO, "craft"),
          requestApproval(STORY, "resize"),
          requestApproval(FEED, "resize", {
            replaced: true,
            status: "not_relevant",
          }),
        ],
      })
    );

    expect(await body().findByText("0 of 2 decided")).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Approve all 2" })
    ).toBeInTheDocument();
    await user.click(body().getByRole("button", { name: "Resize" }));
    expect(body().getByText("Replaced by a newer version")).toBeInTheDocument();
    expect(
      body().queryByRole("button", { name: "Approve IG Feed · 1080 × 1080" })
    ).toBeNull();
  });

  it("counts the viewer's own answer on a still-pending artboard", async () => {
    stubApi();
    renderPage(
      kvRequest({
        approvals: [
          requestApproval(HERO, "craft", { decisions: [agencyDecision()] }),
          requestApproval(STORY, "resize"),
          requestApproval(FEED, "resize"),
        ],
      })
    );

    expect(await body().findByText("1 of 3 decided")).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Approve all 2" })
    ).toBeInTheDocument();
  });

  it("walks to the next undecided artboard", async () => {
    stubApi();
    const user = userEvent.setup();
    renderPage();

    await user.click(
      await body().findByRole("button", { name: "Open Hero board" })
    );
    await body().findAllByText("Craft · Hero board");
    await user.click(body().getByRole("button", { name: "Next undecided" }));
    expect(
      (await body().findAllByText("Resize · IG Story · 1080 × 1920")).length
    ).toBeGreaterThan(0);
    expect(body().queryAllByText("Craft · Hero board")).toHaveLength(0);
  });

  it("sums up the review once the last artboard is decided", async () => {
    const { capture } = stubApi(
      [],
      kvRequest({
        approvals: [
          requestApproval(HERO, "craft", { status: "approved" }),
          requestApproval(STORY, "resize", { status: "approved" }),
          requestApproval(FEED, "resize"),
        ],
      })
    );
    const user = userEvent.setup();
    renderPage(
      kvRequest({
        approvals: [
          requestApproval(HERO, "craft", { status: "approved" }),
          requestApproval(STORY, "resize", { status: "approved" }),
          requestApproval(FEED, "resize"),
        ],
      })
    );

    await user.click(await body().findByRole("button", { name: "Resize" }));
    await user.click(
      body().getByRole("button", { name: "Approve IG Feed · 1080 × 1080" })
    );

    expect(await body().findByRole("status")).toHaveTextContent(
      "All 3 reviewed · 3 approved"
    );
    expect(capture).toHaveBeenCalledWith(
      "client_lane.client_request_completed",
      expect.objectContaining({ artboard_count: 3, changes_count: 0 })
    );
    expect(body().queryByRole("button", { name: /^Approve all/ })).toBeNull();
  });

  it("asks for more time on the whole request", async () => {
    const { post } = stubApi();
    const user = userEvent.setup();
    renderPage();

    await user.click(
      await body().findByRole("button", { name: "I need more time" })
    );
    await user.click(
      await body().findByRole("button", { name: /^Ask for time until/ })
    );

    await waitFor(() => expect(decisionBodies(post)).toHaveLength(1));
    const sent = decisionBodies(post)[0];
    expect(sent).toMatchObject({ outcome: "deferred" });
    expect(sent.deferred_until).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(sent).not.toHaveProperty("approval_ids");
    expect(
      await body().findByText(/^More time asked for until /)
    ).toBeInTheDocument();
  });

  it("says when an artboard closed before the decision landed", async () => {
    const { post } = stubApi();
    post.mockImplementation((async (url: string) => {
      if (url !== DECISION_URL) throw new Error(`unexpected POST ${url}`);
      const closed = kvRequest().approvals!.map((a) =>
        a.id === "ra_g1"
          ? {
              ...a,
              status: "approved" as const,
              decisions: [agencyDecision({ actor: "Bayu" })],
            }
          : a
      );
      return {
        data: {
          data: {
            results: [
              { approval_id: "ra_g1", result: "skipped_closed", decision: null },
            ],
            request: publicRequest(),
            approvals: closed,
          },
        },
      };
    }) as never);
    const user = userEvent.setup();
    renderPage();

    await user.click(
      await body().findByRole("button", { name: "Approve Hero board" })
    );

    expect(
      await body().findByText(
        "One artboard had already closed or moved to a newer request — nothing changed there."
      )
    ).toBeInTheDocument();
    expect(body().getByText("Approved")).toBeInTheDocument();
  });

  it("shows a withdrawn request read-only", async () => {
    stubApi();
    renderPage(
      kvRequest({
        request: publicRequest({ status: "not_relevant" }),
        access: {
          role: "comment",
          expires_at: null,
          can_decide: false,
          verification_required: false,
        },
      })
    );

    expect(
      await body().findByText(/withdrawn by the team/)
    ).toBeInTheDocument();
    expect(body().queryByRole("button", { name: /^Approve/ })).toBeNull();
    expect(body().queryByRole("button", { name: "I need more time" })).toBeNull();
  });

  it("reloads a request that was closed under the viewer, and says so", async () => {
    const { post, get } = stubApi(
      [],
      kvRequest({
        request: publicRequest({ status: "not_relevant" }),
        access: {
          role: "comment",
          expires_at: null,
          can_decide: false,
          verification_required: false,
        },
      })
    );
    post.mockRejectedValue({
      response: { status: 409, data: { code: "round_closed" } },
    });
    const user = userEvent.setup();
    renderPage();

    await user.click(
      await body().findByRole("button", { name: "Approve Hero board" })
    );

    expect(await body().findByRole("alert")).toHaveTextContent(
      /closed while you were deciding/
    );
    await waitFor(() =>
      expect(get.mock.calls.some((c) => c[0] === "public/share-links/tok")).toBe(
        true
      )
    );
    expect(
      await body().findByText(/withdrawn by the team/)
    ).toBeInTheDocument();
    expect(body().queryByRole("button", { name: "Approve Hero board" })).toBeNull();
  });

  it("reloads a stale request on invalid_approval and records nothing", async () => {
    const { post, get } = stubApi();
    post.mockRejectedValue({
      response: { status: 422, data: { code: "invalid_approval" } },
    });
    const user = userEvent.setup();
    renderPage();

    await user.click(
      await body().findByRole("button", { name: "Approve Hero board" })
    );

    expect(await body().findByRole("alert")).toHaveTextContent(
      /changed while you were deciding/
    );
    await waitFor(() =>
      expect(get.mock.calls.some((c) => c[0] === "public/share-links/tok")).toBe(
        true
      )
    );
    expect(body().getByText("0 of 3 decided")).toBeInTheDocument();
  });

  it("asks for a name when the lane was revoked mid-visit, then decides as that guest", async () => {
    const { post } = stubApi();
    const decide = post.getMockImplementation() as (
      url: string,
      input: Record<string, unknown>
    ) => Promise<unknown>;
    let calls = 0;
    post.mockImplementation((async (
      url: string,
      input: Record<string, unknown>
    ) => {
      if (url === DECISION_URL && calls++ === 0) {
        throw {
          response: { status: 403, data: { code: "guest_required" } },
        };
      }
      return decide(url, input);
    }) as never);
    const user = userEvent.setup();
    renderPage();

    await user.click(
      await body().findByRole("button", { name: "Approve Hero board" })
    );
    await body().findByRole("dialog", { name: "Who is deciding?" });
    await user.type(body().getByLabelText("Name"), "Dina Nasution");
    await user.type(body().getByLabelText("Email"), "dina@brand.co.id");
    await user.click(body().getByRole("button", { name: "Continue" }));

    await waitFor(() => expect(decisionBodies(post)).toHaveLength(2));
    expect(decisionBodies(post)[1]).toMatchObject({
      approval_ids: ["ra_g1"],
      guest_name: "Dina Nasution",
      guest_email: "dina@brand.co.id",
    });
  });
});
```

Create `src/components/client-lane/DecisionPage.regression.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  kvRound,
  pendingApproval,
  publicRequest,
} from "@/lib/client-lane/testFixtures";
import type { ShareLinkData, ShareLinkDeck } from "@/lib/client-lane/types";
import { axiosPublic } from "@/services/axios";
import type { DeckDocument } from "@/types/decks";

import { DecisionPage } from "./DecisionPage";

const body = () => within(document.body);

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

/** A deck round with no theme: the hero is the placeholder, the rail is P0a's. */
function deckRound(overrides: Partial<ShareLinkDeck> = {}): ShareLinkDeck {
  return {
    type: "deck",
    brand: { name: "Garuda", slug: "garuda", logo_url: null },
    workspace: { name: "Alva" },
    subject: { id: "d1", title: "Q4 deck", thumbnail_url: null },
    version: { type: "deck_version", id: "dv1", label: "v1", created_at: null },
    items: [],
    approval: pendingApproval(),
    access: {
      role: "comment",
      expires_at: null,
      can_decide: true,
      verification_required: false,
    },
    viewer: { kind: "client", name: "Dina", email: "dina@brand.test" },
    document: { slides: [] } as unknown as DeckDocument,
    deck: { theme: null, slide_themes: null, play_settings: null },
    ...overrides,
  };
}

function renderPage(data: ShareLinkData) {
  vi.spyOn(globalThis, "fetch").mockImplementation(
    (async () =>
      new Response(JSON.stringify({ code: null }), {
        status: 200,
      })) as unknown as typeof fetch
  );
  vi.spyOn(axiosPublic, "get").mockResolvedValue({ data: { data: [] } } as never);
  vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
  return render(<DecisionPage token="tok" initialData={data} />, {
    wrapper: QueryWrapper,
  });
}

beforeEach(() => {
  vi.restoreAllMocks();
  window.localStorage.clear();
  window.sessionStorage.clear();
});

describe("DecisionPage — links that are not requests stay as they were", () => {
  it("keeps a deck round on the round bar and the How-big sheet", async () => {
    const user = userEvent.setup();
    renderPage(deckRound());

    expect(
      await body().findByRole("button", { name: "Approve v1" })
    ).toBeInTheDocument();
    await user.click(body().getByRole("button", { name: "Request changes" }));
    expect(
      await body().findByRole("dialog", { name: "What should change?" })
    ).toHaveTextContent("How big is this?");
    expect(body().queryByText(/ of \d+ decided$/)).toBeNull();
  });

  it("never renders a deck as a request, whatever key rides along", async () => {
    renderPage({ ...deckRound(), request: publicRequest() });

    expect(
      await body().findByRole("button", { name: "Approve v1" })
    ).toBeInTheDocument();
    expect(body().queryByRole("button", { name: /^Approve all/ })).toBeNull();
  });

  it("keeps a legacy KV round link on the round page", async () => {
    renderPage(kvRound());

    expect(
      await body().findByRole("button", { name: "Approve all 3" })
    ).toBeInTheDocument();
    expect(
      body().getByRole("button", { name: "Request changes" })
    ).toBeInTheDocument();
    expect(body().queryByText(/ of \d+ decided$/)).toBeNull();
  });
});
```

- [ ] **Step 2: Run them to watch them fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.request.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.regression.test.tsx
```

Expected: the request suite FAILS (the page renders the round hero; no "Approve Hero board"). The regression suite PASSES at this point — it is the net for Step 4.

- [ ] **Step 3: Public analytics helpers**

Append to the public section of `src/lib/analytics/client-lane-events.ts` (after `trackClientGalleryItemOpened`):

```ts

/* ── Public side — KV request links (spec 2026-10-01 §5.3) ─────────────── */

export type ArtboardDecisionSource = "card" | "focused";

/** One artboard decided on a request link. `outcome` is what was stored
 *  (an approve carrying pins is `approved_with_changes`). */
export const trackClientArtboardDecided = (props: {
  outcome: DecisionOutcome;
  pin_count: number;
  source: ArtboardDecisionSource;
}) => safeCapture("client_lane.client_artboard_decided", props);

export const trackClientApproveAll = (props: {
  /** Artboards approved in the one call. */
  count: number;
  /** Undecided artboards left out because this viewer pinned them. */
  skipped_with_pins: number;
}) => safeCapture("client_lane.client_approve_all", props);

/** Every non-success exit of a request-link decision post. */
export const trackClientRequestDecisionFailed = (props: {
  reason: string;
  http_status: number | null;
}) => safeCapture("client_lane.client_decision_failed", props);

/** The request left `pending` with this viewer's decision. */
export const trackClientRequestCompleted = (props: {
  artboard_count: number;
  changes_count: number;
}) => safeCapture("client_lane.client_request_completed", props);
```

- [ ] **Step 4: Wire the branch into `DecisionPage.tsx`** (line numbers are the file before this task)

1. Imports. Line 6-13: add `postRequestDecision`. Lines 14-23: add `type ArtboardDecisionSource, trackClientApproveAll, trackClientArtboardDecided, trackClientRequestCompleted, trackClientRequestDecisionFailed`. After line 33 add `import { plural, requestOf } from "@/lib/client-lane/requests";`. In the storage import (35-43) add `type RequestDecisionDraft`. After line 59 (`PinList`) add:

```tsx
import {
  FocusedArtboardPanel,
  RequestActionBar,
  RequestOutcomeBanner,
  RequestOverview,
} from "./RequestRail";
```

After the `./kv/roundItems` import (62-67) add:

```tsx
import type { ArtboardIntent } from "./kv/KvRequestHero";
import {
  approveAllPlan,
  nextUndecided,
  requestArtboards,
  requestProgress,
  requestVersionIds,
  type RequestArtboard,
} from "./kv/requestItems";
```

After line 69 (`MoreTimeSheet`) add `import { NewVersionNoteSheet } from "./sheets/NewVersionNoteSheet";`. After the `PlanHero` dynamic (lines 92-95) add:

```tsx
const KvRequestHero = dynamic(
  () => import("./kv/KvRequestHero").then((m) => m.KvRequestHero),
  { ssr: false, loading: HERO_LOADING }
);
```

2. `OpenSheet` (97-104) gains `| { kind: "newVersionNote"; artboardId: string; source: ArtboardDecisionSource }`. After it add:

```tsx
/** What a request-link decision was, for its analytics (spec §5.3). */
type RequestMeta =
  | { kind: "artboard"; source: ArtboardDecisionSource; pinCount: number }
  | { kind: "approve_all"; count: number; skippedWithPins: number }
  | { kind: "deferred" }
  | { kind: "resumed" };
```

3. After `const [error, setError] = …` (line 190) add `const [notice, setNotice] = useState<string | null>(null);`.

4. After `const versionId = …` (line 227) add:

```tsx
  /**
   * A request link (spec 2026-10-01 §5.1): one decision per artboard. Deck,
   * plan, KV view and legacy KV round links keep the page below unchanged.
   */
  const req = useMemo(() => requestOf(data), [data]);
  const requestOpen = req?.request.status === "pending";
  const requestCanDecide = req !== null && data.access.can_decide && requestOpen;
```

5. After the `roundItems` memo (252-255) add:

```tsx
  const artboards = useMemo<RequestArtboard[]>(
    () =>
      req && data.type === "kv_file"
        ? requestArtboards(data.document, req, viewerName)
        : [],
    [req, data, viewerName]
  );
  /** What pins land on: the request's artboards, else the round's items. */
  const pinItems: KvRoundItem[] = req ? artboards : roundItems;
  const focusedArtboard: RequestArtboard | null = req
    ? artboards.length === 1
      ? artboards[0]
      : (artboards.find((a) => a.id === focusedItemId) ?? null)
    : null;
```

6. Line 293 becomes `const approvalId = data.approval?.id ?? data.request?.id ?? null;` (a request link resets this visit's pins the same way when the link moves on).

7. The `pins` memo (319-322) becomes:

```tsx
  const pins = useMemo<PagePin[]>(
    () =>
      pinsFromComments(
        comments,
        req ? requestVersionIds(req) : roundVersionIds(data)
      ),
    [comments, data, req]
  );
```

8. After the `decisionPins` memo (328-331) add:

```tsx
  /** This visit's pins on one artboard — what its decision carries. */
  const pinsOn = useCallback(
    (a: RequestArtboard) =>
      decisionPins.filter(
        (id) => pins.find((p) => p.id === id)?.version === a.versionId
      ),
    [decisionPins, pins]
  );
  const allPlan = useMemo(
    () =>
      approveAllPlan(
        artboards,
        new Set(
          decisionPins
            .map((id) => pins.find((p) => p.id === id)?.version)
            .filter((v): v is string => Boolean(v))
        )
      ),
    [artboards, decisionPins, pins]
  );
  const progress = useMemo(() => requestProgress(artboards), [artboards]);
```

9. After `submitDecision` (487-492) add:

```tsx
  // Request links (spec §4.6 C-3): decisions name their artboards. Same
  // identity ladder and `guest_required` retry as `doSubmit`.
  const doSubmitRequest = useCallback(
    (draft: RequestDecisionDraft, meta: RequestMeta, g: GuestIdentity | null) => {
      void (async () => {
        setBusy(true);
        setError(null);
        setNotice(null);
        const wasPending = data.request?.status === "pending";
        try {
          const res = await postRequestDecision(
            token,
            {
              ...draft,
              pins: draft.pins?.length ? draft.pins : undefined,
              ...(g ? { guest_name: g.name, guest_email: g.email } : {}),
            },
            laneCode
          );
          clearDraft(token);
          const decided = res.results.filter((r) => r.result === "decided");
          if (meta.kind === "artboard") {
            trackClientArtboardDecided({
              outcome: decided[0]?.decision?.outcome ?? draft.outcome,
              pin_count: meta.pinCount,
              source: meta.source,
            });
          } else if (meta.kind === "approve_all") {
            trackClientApproveAll({
              count: meta.count,
              skipped_with_pins: meta.skippedWithPins,
            });
          } else if (meta.kind === "deferred") {
            trackClientDecisionSubmitted({
              subject_type: data.type,
              outcome: "deferred",
              verified: g === null,
              pin_count: 0,
              has_note: Boolean(draft.note),
              deferred: true,
              resumed: false,
              item_count: res.approvals.length,
            });
          }
          if (
            wasPending &&
            res.request.status !== "pending" &&
            res.request.status !== "not_relevant"
          ) {
            const live = res.approvals.filter((a) => !a.replaced);
            trackClientRequestCompleted({
              artboard_count: live.length,
              changes_count: live.filter((a) => a.status === "changes_required")
                .length,
            });
          }
          if (
            decided.some((r) => r.decision?.advisory) &&
            res.request.status === "pending"
          ) {
            writeAdvisoryRound(token, res.request.id);
            setAdvisoryRound(res.request.id);
          }
          const skipped = res.results.length - decided.length;
          if (skipped > 0) {
            setNotice(
              skipped === 1
                ? "One artboard had already closed or moved to a newer request — nothing changed there."
                : `${skipped} artboards had already closed or moved to a newer request — nothing changed there.`
            );
          }
          setData((prev) => ({
            ...prev,
            request: res.request,
            approvals: res.approvals,
            access: {
              ...prev.access,
              can_decide:
                prev.access.role === "comment" &&
                res.request.status === "pending",
            },
          }));
          setSheet(null);
        } catch (e) {
          const err = publicApiError(e);
          trackClientRequestDecisionFailed({
            reason: failureReason(err),
            http_status: err.status,
          });
          if (err.code === "verification_required") {
            writeDraft(token, draft);
            setVerifySent(false);
            setSheet({
              kind: "verify",
              email: g?.email ?? data.viewer.email ?? "",
            });
          } else if (err.code === "guest_required") {
            setLaneRejected(true);
            clearGuest();
            setGuest(null);
            afterIdentityRef.current = (identity) =>
              doSubmitRequest(draft, meta, identity);
            setSheet({ kind: "name" });
          } else if (
            err.code === "round_closed" ||
            err.code === "invalid_approval" ||
            isStalePinsError(e)
          ) {
            // `409 round_closed`: the request was withdrawn (or every
            // artboard replaced) under us. `422 invalid_approval` / a `pins`
            // 422: the request on screen is stale. Nothing was recorded —
            // say so and load the request as it is now.
            clearDraft(token);
            setSheet(null);
            setError(
              err.code === "round_closed"
                ? "This request was closed while you were deciding — here is where it stands now."
                : "This request changed while you were deciding — it has been reloaded. Decide again."
            );
            await refresh();
          } else if (
            err.code === "note_required" &&
            draft.approval_ids?.length === 1
          ) {
            // The api's own guard (no pins, no note) — ask for the note.
            setSheet({
              kind: "newVersionNote",
              artboardId: draft.approval_ids[0],
              source: meta.kind === "artboard" ? meta.source : "card",
            });
          } else {
            setError(
              err.message ??
                "That didn't go through. Check your connection and try again."
            );
          }
        } finally {
          setBusy(false);
        }
      })();
    },
    [
      token,
      laneCode,
      data.type,
      data.request?.status,
      data.viewer.email,
      refresh,
    ]
  );

  const submitRequest = useCallback(
    (draft: RequestDecisionDraft, meta: RequestMeta) => {
      withIdentity((g) => doSubmitRequest(draft, meta, g));
    },
    [withIdentity, doSubmitRequest]
  );

  /** ✓ / ✎ on a card or in the focused view (spec §5.1). */
  const decideArtboard = (
    a: RequestArtboard,
    intent: ArtboardIntent,
    source: ArtboardDecisionSource
  ) => {
    const own = pinsOn(a);
    if (intent === "approve" || own.length > 0) {
      submitRequest(
        {
          approval_ids: [a.id],
          outcome: intent === "approve" ? "approved" : "changes_required",
          pins: own,
        },
        { kind: "artboard", source, pinCount: own.length }
      );
      return;
    }
    // A new version with no pins needs words (spec D-5).
    setSheet({ kind: "newVersionNote", artboardId: a.id, source });
  };

  const approveAll = () =>
    submitRequest(
      { approval_ids: allPlan.ids, outcome: "approved" },
      {
        kind: "approve_all",
        count: allPlan.ids.length,
        skippedWithPins: allPlan.skippedWithPins,
      }
    );

  const goNextUndecided = () => {
    const next = nextUndecided(artboards, focusedArtboard?.id ?? null);
    if (!next) return;
    setFocusedItemId(next.id);
    setActivePinId(null);
  };
```

10. The auto-submit effect (496-504) becomes:

```tsx
  useEffect(() => {
    if (!laneReady || autoSubmittedRef.current || !hasLane) return;
    if (req) {
      const draft = readDraft<RequestDecisionDraft>(token);
      if (!draft || !requestCanDecide) return;
      autoSubmittedRef.current = true;
      submitRequest(draft, { kind: "resumed" });
      return;
    }
    const draft = readDraft(token);
    if (!draft || !canDecide) return;
    autoSubmittedRef.current = true;
    submitDecision(draft, true);
  }, [
    laneReady,
    hasLane,
    canDecide,
    requestCanDecide,
    req,
    token,
    submitDecision,
    submitRequest,
  ]);
```

11. `pinnable` (561-566) becomes:

```tsx
  const pinnable =
    commentsEnabled &&
    !busy &&
    (data.type === "deck"
      ? versionId !== null
      : data.type === "kv_file" &&
        (req ? artboards.some((a) => !a.replaced) : roundItems.length > 0));
```

12. In `selectPin` (701) and `pinPartLabel` (720) replace `roundItems` with `pinItems`.

13. `hero` (735): prepend a branch so it reads `const hero = req && data.type === "kv_file" ? ( <KvRequestHero …/> ) : data.type === "deck" && deck?.theme ? …` with:

```tsx
      <KvRequestHero
        artboards={artboards}
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
            ? (a, x, y) =>
                placePin(
                  { stage: a.phase, version: a.versionId, part: a.part },
                  x,
                  y
                )
            : undefined
        }
        onSelectPin={selectPin}
        onDecide={
          requestCanDecide
            ? (a, intent) => decideArtboard(a, intent, "card")
            : undefined
        }
        busy={busy}
      />
```

14. After `nextVersionLabel` (799-801) add:

```tsx
  const waitingNames = req
    ? req.request.approvers
        .filter((a) => !a.decided)
        .map((a) => a.name)
        .join(", ")
    : "";
  /** Same hint as a round's (a named approver on the plain link), per request. */
  const showRequestApproverHint =
    req !== null &&
    requestCanDecide &&
    req.request.approvers.some((a) => !a.decided) &&
    !(data.viewer.kind === "client" && !laneRejected);
  const noteArtboard =
    sheet?.kind === "newVersionNote"
      ? artboards.find((a) => a.id === sheet.artboardId)
      : undefined;
```

15. The page container (line 814): append the phone padding for the fixed action bar — the className becomes a template literal ending `…lg:gap-x-8${req && requestCanDecide ? " max-lg:pb-40" : ""}`.

16. Header: line 853 becomes `{(req ? requestCanDecide : canDecide) ? " · Needs your decision" : ""}` and line 859 becomes:

```tsx
                {req
                  ? `Request ${req.request.number} · ${plural(progress.total, "artboard")}`
                  : withItemCount(data.version.label, itemCount)}
```

17. `<main>` (865-886) becomes:

```tsx
        <main className="flex min-w-0 flex-col gap-5">
          {hero}
          {!req && approval && data.type !== "campaign" && (
            <VersionStrip current={data.version} rounds={approval.rounds} />
          )}
          {pins.length > 0 && !focusedArtboard && (
            <PinList
              pins={pins}
              threads={threads}
              onReply={commentsEnabled ? replyToPin : undefined}
              versionLabel={
                req ? `Request ${req.request.number}` : data.version.label
              }
              activeId={activePinId}
              partLabel={pinPartLabel}
              groups={
                data.type === "kv_file" && pinItems.length > 1
                  ? pinGroups(pinItems, pins)
                  : undefined
              }
              onSelect={selectPin}
            />
          )}
        </main>
```

18. `<aside>` (888-987): its opening tag becomes

```tsx
        <aside
          className={[
            "flex flex-col gap-4 lg:sticky lg:top-6",
            // Phone: the request's overview leads ("5 of 8"); a focused
            // artboard keeps its artwork first.
            req && !focusedArtboard ? "max-lg:order-first" : "",
          ].join(" ")}
        >
```

Wrap the existing `approval?.message` section and the approvers section (889-921) as the `else` of:

```tsx
          {req ? (
            <>
              <RequestOverview
                request={req.request}
                workspaceName={data.workspace.name}
                progress={progress}
                className={focusedArtboard ? "max-lg:hidden" : undefined}
                footer={
                  showRequestApproverHint ? (
                    <p className="border-t border-white/5 pt-3 font-geist text-textXs text-text-inverse-subtle">
                      Named as an approver? Only your personal link counts.{" "}
                      <button
                        type="button"
                        className="font-medium text-text-inverse underline decoration-white/30 underline-offset-2 transition-all duration-200 ease-out hover:decoration-white"
                        onClick={openApproverLink}
                      >
                        Email me my link
                      </button>
                    </p>
                  ) : null
                }
              />
              {requestOpen && advisoryRound === req.request.id && (
                <p className="rounded-2xl border border-white/10 bg-white/5 p-4 font-geist text-textSm text-text-inverse">
                  Your decisions are recorded as advisory — waiting on{" "}
                  {waitingNames || "the named approvers"}.
                </p>
              )}
              <RequestOutcomeBanner request={req.request} progress={progress} />
              {focusedArtboard && (
                <FocusedArtboardPanel
                  artboard={focusedArtboard}
                  includedPins={pinsOn(focusedArtboard).length}
                >
                  <PinList
                    pins={pins.filter(
                      (p) => p.version === focusedArtboard.versionId
                    )}
                    threads={threads}
                    onReply={commentsEnabled ? replyToPin : undefined}
                    versionLabel={`v${focusedArtboard.round}`}
                    activeId={activePinId}
                    onSelect={selectPin}
                  />
                </FocusedArtboardPanel>
              )}
            </>
          ) : (
            <>
              {/* the existing `approval?.message` section and approvers section, unchanged */}
            </>
          )}
```

Before the existing `{error && …}` block (923) add:

```tsx
          {notice && (
            <p
              role="status"
              className="rounded-xl bg-white/5 px-3 py-2 font-geist text-textSm text-text-inverse-subtle"
            >
              {notice}
            </p>
          )}
```

Wrap the TerminalBanner, advisory card, `DecisionBar` and read-only line (932-979) as the `else` of:

```tsx
          {req ? (
            <>
              {requestCanDecide && (focusedArtboard || !progress.complete) && (
                <RequestActionBar
                  focused={focusedArtboard}
                  plan={allPlan}
                  nextId={
                    nextUndecided(artboards, focusedArtboard?.id ?? null)?.id ??
                    null
                  }
                  busy={busy}
                  onApproveAll={approveAll}
                  onMoreTime={() => setSheet({ kind: "moreTime" })}
                  onDecide={(a, intent) => decideArtboard(a, intent, "focused")}
                  onNext={goNextUndecided}
                />
              )}
              {requestOpen && !data.access.can_decide && (
                <p className="text-center font-geist text-textXs text-text-inverse-subtlest">
                  Shared for review — this link cannot record a decision.
                </p>
              )}
            </>
          ) : (
            <>
              {/* the existing TerminalBanner, advisory card, DecisionBar and read-only line, unchanged */}
            </>
          )}
```

The footer stays shared.

19. Sheets: wrap `<HowBigSheet …/>` in `{!req && ( … )}`. `MoreTimeSheet`'s `onSubmit` becomes:

```tsx
        onSubmit={(deferredUntil, note) =>
          req
            ? submitRequest(
                {
                  outcome: "deferred",
                  deferred_until: deferredUntil,
                  note: note || undefined,
                },
                { kind: "deferred" }
              )
            : submitDecision({
                outcome: "deferred",
                deferred_until: deferredUntil,
                note: note || undefined,
              })
        }
```

`PinNoteSheet`'s `versionLabel` becomes:

```tsx
        versionLabel={
          req
            ? `v${artboards.find((a) => a.versionId === pinDraft?.version)?.round ?? 1}`
            : data.version.label
        }
```

and after `PinNoteSheet` add:

```tsx
      {req && (
        <NewVersionNoteSheet
          key={
            sheet?.kind === "newVersionNote"
              ? `nv-${sheet.artboardId}`
              : "nv-closed"
          }
          open={sheet?.kind === "newVersionNote"}
          caption={noteArtboard?.caption ?? ""}
          busy={busy}
          onSubmit={(note) => {
            if (sheet?.kind !== "newVersionNote") return;
            submitRequest(
              {
                approval_ids: [sheet.artboardId],
                outcome: "changes_required",
                note,
              },
              { kind: "artboard", source: sheet.source, pinCount: 0 }
            );
          }}
          onClose={() => setSheet(null)}
        />
      )}
```

`useCallback`, `useMemo` and the `KvRoundItem` type are already imported (lines 4 and 66).

- [ ] **Step 5: Run every page suite**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.request.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.regression.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/DecisionPage.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && wc -c src/components/client-lane/DecisionPage.request.test.tsx
```

Expected: 15 + 3 PASS, the existing DecisionPage suite unchanged from Task 0, the new file < 45 KB (≈ 20 KB). If "sums up the review…" finds two `status` regions (the notice is also `role="status"`), scope it with `findByText("All 3 reviewed · 3 approved")` instead — never weaken the assertion text.

- [ ] **Step 6: Mutation checks**

1. In `decideArtboard`, drop `|| own.length > 0` → "asks for a new version with this artboard's pins, at once" FAILS (the note sheet opens). Restore.
2. In the `allPlan` memo, pass `new Set()` instead of the pinned versions → "skips the pinned artboard in Approve all" FAILS. Restore.
3. Make `requestCanDecide` ignore `requestOpen` → "shows a withdrawn request read-only" FAILS. Restore.
4. Remove the `setNotice(…)` call → "says when an artboard closed before the decision landed" FAILS. Restore.
5. In `doSubmitRequest`'s `guest_required` branch, retry with `doSubmitRequest(draft, meta, null)` → "asks for a name when the lane was revoked…" FAILS. Restore.
6. In `lib/client-lane/requests.ts`'s `requestOf`, drop `data.type !== "kv_file" ||` → regression "never renders a deck as a request, whatever key rides along" FAILS. Restore.
7. Delete `await refresh();` from the stale-request branch → "reloads a request that was closed under the viewer, and says so" and "reloads a stale request on invalid_approval…" FAIL. Restore.

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/analytics/client-lane-events.ts src/components/client-lane/DecisionPage.tsx src/components/client-lane/DecisionPage.request.test.tsx src/components/client-lane/DecisionPage.regression.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-lane-events|client-lane/DecisionPage"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: nothing; 895.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/analytics/client-lane-events.ts src/components/client-lane/DecisionPage.tsx src/components/client-lane/DecisionPage.request.test.tsx src/components/client-lane/DecisionPage.regression.test.tsx && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): request links decide per artboard — cards, focused view, Approve all, completion

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Title, description and OG card for request links

A request link's WhatsApp card and tab title should name the request and its artboards. (Spec gap — §5 does not mention it.) C-1 already sends `version.label = "Request {n}"` for a request link, so the card's version line needs no change; but `approval` is `null` there, so without this the card shows no "Needs your decision" pill and the alt counts `items` (replaced artboards included) as "items".

**Files:**
- Modify: `src/lib/client-lane/round.ts`, `src/lib/client-lane/round.test.ts`, `src/app/s/[token]/page.tsx` (line 77), `src/app/s/[token]/opengraph-image.tsx` (imports 7-11, line 147, lines 240-256)

**Interfaces:**
- Consumes: `requestOf`, `plural` (Task 1).
- Produces: `ogPill(data): string | null` (the pill text while the round / request is open, else `null`); `shareImageAlt` / `shareTitle` name a request; `ogDecisionPill(count, noun = "items")`.

- [ ] **Step 1: Write the failing tests**

Append to `src/lib/client-lane/round.test.ts` (add `ogPill` to the `./round` import and `FEED, HERO, STORY, kvRequest, publicRequest, requestApproval` to the fixtures import):

```ts
describe("request links", () => {
  it("names the request and its artboards in the title and alt", () => {
    expect(shareImageAlt(kvRequest())).toBe(
      "Ramadan hero · Request 2 · 3 artboards"
    );
    expect(shareTitle(kvRequest())).toBe(
      "For Dina · Ramadan hero · Request 2 · 3 artboards — Garuda via Alva"
    );
  });

  it("counts only artboards still in the request", () => {
    const data = kvRequest({
      approvals: [
        requestApproval(HERO, "craft"),
        requestApproval(STORY, "resize"),
        requestApproval(FEED, "resize", { replaced: true, status: "not_relevant" }),
      ],
    });
    expect(shareImageAlt(data)).toBe("Ramadan hero · Request 2 · 2 artboards");
  });

  it("pills the OG card only while the round or request is open", () => {
    expect(ogPill(kvRequest())).toBe("3 artboards · Needs your decision");
    expect(
      ogPill(kvRequest({ request: publicRequest({ status: "approved" }) }))
    ).toBeNull();
    expect(ogPill(kvRound())).toBe("3 items · Needs your decision");
    expect(ogPill(kvRound({ approval: null }))).toBeNull();
  });
});
```

- [ ] **Step 2: Run to watch it fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/round.test.ts
```

Expected: FAIL — `ogPill` is not exported.

- [ ] **Step 3: Implement**

In `src/lib/client-lane/round.ts` add `import { plural, requestOf } from "./requests";`, change `ogDecisionPill` to:

```ts
/** The OG card's pill while the round (or request) is open. */
export function ogDecisionPill(
  count: number,
  noun: "items" | "artboards" = "items"
): string {
  return count > 1
    ? `${count} ${noun} · Needs your decision`
    : "Needs your decision";
}
```

and add after it:

```ts
/** Artboards still in a request link's request (replaced ones moved on). */
function requestArtboardCount(data: ShareLinkData): number | null {
  const view = requestOf(data);
  return view ? view.approvals.filter((a) => !a.replaced).length : null;
}

/** The OG pill text while a decision is open, else null. */
export function ogPill(data: ShareLinkData): string | null {
  const view = requestOf(data);
  if (view) {
    return view.request.status === "pending"
      ? ogDecisionPill(requestArtboardCount(data) ?? 0, "artboards")
      : null;
  }
  return data.approval?.status === "pending"
    ? ogDecisionPill(roundItemCount(data))
    : null;
}
```

`shareImageAlt` becomes:

```ts
/** The OG image's alt: "{title} · v2 · 3 items" / "{title} · Request 2 · 3 artboards". */
export function shareImageAlt(data: ShareLinkData): string {
  const artboards = requestArtboardCount(data);
  if (artboards !== null) {
    // `version.label` is "Request {n}" on a request link (C-1).
    return `${data.subject.title} · ${data.version.label} · ${plural(artboards, "artboard")}`;
  }
  return `${data.subject.title} · ${withItemCount(data.version.label, roundItemCount(data))}`;
}
```

In `src/app/s/[token]/page.tsx` line 77 becomes:

```ts
  const description =
    data.approval?.message?.trim() ||
    (data.type === "kv_file" ? data.request?.message?.trim() : "") ||
    "Needs your decision";
```

In `src/app/s/[token]/opengraph-image.tsx`: the import (7-11) becomes `import { ogPill, ogThumbnailUrl } from "@/lib/client-lane/round";`; line 147 becomes `const pill = ogPill(data);` (line 208's `{data.version.label}` already reads "Request {n}"); the pill block (240-256) tests `{pill ? ( … {pill} … ) : ( <div style={{ display: "flex" }} /> )}`.

- [ ] **Step 4: Run, mutate, gate, commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/round.test.ts
```

Expected: all PASS (the P0a title tests unchanged). Mutation: in `ogPill`, return the request pill regardless of status → "pills the OG card only while…" FAILS. Restore.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/client-lane/round.ts src/lib/client-lane/round.test.ts "src/app/s/[token]/page.tsx" "src/app/s/[token]/opengraph-image.tsx") && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "client-lane/round|app/s/\[token\]"; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: nothing; 895.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/client-lane/round.ts src/lib/client-lane/round.test.ts "src/app/s/[token]/page.tsx" "src/app/s/[token]/opengraph-image.tsx" && /usr/bin/git commit -m "$(cat <<'EOF'
feat(web): a request link's title and OG card name the request and its artboards

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Gates, smoke, tri-mode, Lark taxonomy

**Files:**
- Modify: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:** none.

- [ ] **Step 1: Every suite, one per run**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && for f in src/lib/client-lane/requests.test.ts src/lib/client-lane/statusTone.test.ts src/lib/client-lane/versionLabels.test.ts src/lib/client-lane/round.test.ts src/services/client-lane.test.tsx src/components/frndos/v2/FilterChips.test.tsx src/components/frndos/v2/PageToolbar.test.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/components/client-lane/agency/RequestApprovalPanel.test.tsx src/components/client-lane/agency/KvRequestForm.test.tsx src/components/client-lane/agency/KvApprovalRequestsSection.test.tsx src/components/studio/kv-generator/KvSharePanel.test.tsx src/components/brands/campaign-planner/SharePlanDialog.test.tsx src/components/client-lane/kv/requestItems.test.ts src/components/client-lane/kv/KvRequestHero.test.tsx src/components/client-lane/kv/KvRoundHero.test.tsx src/components/client-lane/kv/KvLinkGallery.test.tsx src/components/client-lane/kv/roundItems.test.ts src/components/client-lane/RequestRail.test.tsx src/components/client-lane/DecisionPage.test.tsx src/components/client-lane/DecisionPage.request.test.tsx src/components/client-lane/DecisionPage.regression.test.tsx src/lib/studio/kv/kvCommentAdapter.test.ts; do echo "== $f"; bun test "$f" 2>&1 | tail -3; done
```

(`for f in …` with literal words is fine in zsh.) Expected: every file `0 fail`. Record the per-file pass counts in the track file.

- [ ] **Step 2: Type, lint and the §11.3 review gate**

Let `BASE` be the Part A base SHA recorded in Task 0 (the tip before Task 0's commit).

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"; FILES=(${(f)"$(/usr/bin/git diff --name-only BASE..HEAD -- 'src/*.ts' 'src/*.tsx')"}); npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -F -f <(printf '%s\n' "${FILES[@]}"); npx eslint "${FILES[@]}"
```

Expected: 895, the grep prints nothing, eslint clean. If Task 0 left "api.md diff pending", run its `PRD-COPIES-IDENTICAL` diff now (api Task 1 must have landed) and clear the Open item. Then the spec §11.3 checks over this branch's ADDED lines:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git diff -U0 BASE..HEAD -- 'src/*.tsx' | /usr/bin/grep '^+' | /usr/bin/grep -v '^+++' | /usr/bin/grep -nE -- '-\[[0-9]+px\]|\btext-white\b|text-gray-[0-9]|\[#[0-9a-fA-F]{3,6}\]'
```

Expected: only lines this plan carried over unchanged (the safe-area `pb-[max(...)]` is not matched). Anything else → fix with tokens and re-run the owning suite.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && for f in ${(f)"$(/usr/bin/git diff --name-only BASE..HEAD -- 'src/*.tsx')"}; do if /usr/bin/grep -q 'from "@/components/frndos/v2"' "$f" && /usr/bin/grep -qE 'from "@/components/frndos(/[A-Z][A-Za-z]*)?"' "$f"; then echo "MIX $f"; fi; done
```

Expected: no `MIX` line (Task 6 ended `RequestApprovalPanel.tsx`'s pre-existing mix). Any hit → move the v1 piece into its own wrapper file, as `StatusPill.tsx` does.

- [ ] **Step 3: Manual smoke (needs the api branch on :9191)**

Ask Daffa first — this uses his running services. With the api worktree `api/.worktrees/client-lane-multi-item` serving `:9191` (confirm with `lsof -a -p <pid> -d cwd -sTCP:LISTEN`) and this worktree on another port (`PORT=3001 bun dev`):
1. KV file with two Craft boards + three Resize tiles marked ready: Share → "Request approval · 5 new ready". Form: pills `Craft 2 · Resize 3`, turn Resize off → "2 artboards in this request"; add an approver; Send → "Request 1 is out for approval"; Done → the row "Request 1 · 2 artboards · Waiting on …".
2. New link → no toggle; Create link works; View links shows `1/3`.
3. Open the request link in a private window: grid with "No decision yet"; ✓ a card → "1 of 2 decided" without reload; ✎ the other without pins → note sheet; completion line appears; the agency row turns "Approved"/"Changes".
4. Phone width (DevTools 390px): overview first, one column, Approve all fixed at the bottom; tapping a card shows the artwork first, pins below, Approve / Request new version fixed.
5. Mark a third Craft board, send Request 2 that includes an artboard still waiting in Request 1 → the form shows "— replaces v1, still waiting"; Request 1's row shows "Replaced in Request 2"; its old link greys that card "Replaced by a newer version".
6. OG card: `curl -s http://localhost:3001/s/<token>/opengraph-image -o /tmp/og.png && open /tmp/og.png` → "Key visual · Request 1", "2 artboards · Needs your decision".

- [ ] **Step 4: Tri-mode visual check (agency only)**

Profile menu → Miscellaneous → Theme: Midnight, Aurora, Daylight. In each, the Share dialog's Approval requests section, a request row (pill, •••, expanded detail with avatars and decision rows), the request form (phase chips, approver chips, message, Decide by picker), the withdraw confirm. Nothing unreadable, no dark slab in Daylight. The `/s/` page stays dark in all three.

- [ ] **Step 5: Track file + Lark taxonomy rows for Daffa**

Tick Tasks 1-11 in the track's Part A checklist and append to the Session Log:

```markdown
### <date> — daffa (plan executor)
- Part A Tasks 1–11 done on `feature/daffa/vc-client-lane-multi-item` (<n> commits since <BASE>). Suites: <file — count> … all 0 fail. tsc 895 (baseline 895), 0 in touched files; eslint clean; §11.3 grep clean; no v1/v2 mix.
- Manual smoke: <done / pending — which steps>. Tri-mode: <done / pending>.
- PENDING (human): Lark "frndOS Event Taxonomy" rows below.
```

Lark rows for Daffa to add (https://fcn.sg.larksuite.com/wiki/DMbKwqbzQiWrXSkha5zl1wFvgod), section *Client Lane*:

| Event | Status | Trigger | Properties |
|---|---|---|---|
| `client_lane.approval_request_form_opened` | new | Share dialog "Request approval · n new ready" click (Part B adds tray / top bar) | `source` (`share_dialog`\|`tray`\|`top_bar`), `ready_total` |
| `client_lane.approval_request_sent` | new | `POST v1/approval-requests` 201 | `request_number`, `artboard_count`, `phases[]`, `approver_count`, `has_deadline` |
| `client_lane.approval_request_send_failed` | new | that POST failed | `reason` (api code \| `network` \| `unknown`), `http_status` |
| `client_lane.approval_request_withdrawn` | new | Withdraw confirmed and succeeded | `request_number`, `artboard_count` |
| `client_lane.approval_request_withdraw_failed` | new | Withdraw failed | `request_number`, `reason`, `http_status` |
| `client_lane.approval_request_resent` | new | Resend succeeded | `request_number`, `reminded_count` |
| `client_lane.approval_request_resend_failed` | new | Resend failed | `request_number`, `reason`, `http_status` |
| `client_lane.client_artboard_decided` | new (public, PII-free) | a card ✓/✎ or a focused decision saved | `outcome` (stored), `pin_count`, `source` (`card`\|`focused`) |
| `client_lane.client_approve_all` | new (public) | Approve all saved | `count`, `skipped_with_pins` |
| `client_lane.client_decision_failed` | new (public) | a request-link decision post failed | `reason`, `http_status` |
| `client_lane.client_request_completed` | new (public) | the request left `pending` with this viewer's decision | `artboard_count`, `changes_count` |
| `client_lane.approval_mode_toggled` | **deprecated** | the New-link toggle was removed (spec 2026-10-01 §5.2) | — (hide the PostHog definition) |
| `client_lane.approval_link_shared` | changed | also fires from a request row's Copy link; for KV, `round` carries the request number | unchanged schema |
| `client_lane.approver_link_copied` / `_copy_failed` | changed | also fires from a request's approver row; for KV, `round` = request number | unchanged schema |
| `client_lane.decision_submitted` | changed | on a request link fires only for "I need more time" (`outcome: deferred`, `item_count` = artboards) | unchanged schema |

- [ ] **Step 6: Commit the track**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add docs/tracks/client-lane-multi-item.track.md && /usr/bin/git commit -m "$(cat <<'EOF'
docs(web): track KV approval requests Part A — gates and verification

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

## Spec coverage (self-review)

| Spec | Task |
|---|---|
| §4.5 agency endpoints (preview, create, list, withdraw, resend; `nothing_ready`, `too_many_items`, `already_a_member`) | 1, 4, 5 |
| §4.6 C-1 request shape (`version.type = approval_request`, `access.can_decide` = pending), C-3 `approval_ids` / results / `note_required` / `409 round_closed` / `422 invalid_approval` / deferred without ids, C-4 pins per approval version | 1, 7, 9, 10 |
| Contract error codes: create `409 round_conflict`, withdraw `409 round_closed`, resend `422 no_named_approvers` | 4, 5 |
| §5.1 laptop grid + states + ✓/✎; rail message, progress, Decide by, Approve all (`Approve 7 · 1 has pins`), I need more time; focused view with pins, `n pins included`, Approve / Request new version, Next undecided | 7, 8, 9 |
| §5.1 phone: one column, overview first, fixed Approve all / bottom bar | 7 (`columns={1}`), 8 (fixed bar), 9 (`order-first`) — manual check Task 11 |
| §5.1 decisions saved at once; note sheet without pins; completion summary; advisory card, approver hint, name gate, threads, dark scope kept; HowBig / DecisionBar not on request links | 8, 9 |
| §5.2 two sections, header button + disabled reasons, rows with Copy link, expanded per-artboard rows, approvers + personal links, Resend / Withdraw, toggle removed, form (pills + counts, Already approved, Waiting (api R2), replaced notes, approvers, message, Decide by, send step), no KV status block | 3, 4, 5, 6 |
| §5.3 analytics + Lark rows | 4, 5, 9, 11 |
| §4.8 contract notes byte-identical | 0 |
| §11 frndOS map, tokens, tri-mode, one file one architecture | every UI task; gates in 11 |
| Deck / plan unchanged | 3 (`RequestApprovalPanel.test`, status block), 6, 9 (`DecisionPage.regression.test`) |
