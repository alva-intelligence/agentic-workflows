# Client Lane KV Approval Requests — Web Part B (canvas) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every step that writes, runs or mutation-checks a test is titled **(test)** — in fast mode those steps may be skipped as a group; everything else may not.

**Goal:** The KV canvas itself tells the agency what is ready for the client and what the client said: a "Ready for client" tray above the bottom nav, a top-bar slot that is a **Ready for client** button until a request exists and a status chip + popover after, a request form that drops down under that slot, and a verdict chip on every artboard (boards, Resize tiles, Motion tiles) — all reading the same two queries the Share dialog reads.

**Architecture:** One pure module (`lib/client-lane/canvasApproval.ts`) owns every rule — slot state and chip text, per-artboard verdicts and their chip text, artboard-key routing, the jump plan, the form prefill. Two new frndOS v2 primitives (`FloatingActionBar`, `CountBadge`) carry the tray and the count. Four client-lane v2 components (`KvApprovalStatusList`, `KvClientApprovalSlot`, `KvReadyForClientTray`, plus the extracted `useRequestActions`) sit on top of Part A's hooks. Canvas chrome reads verdicts through a React context (`ArtboardVerdictsProvider`) so nothing is prop-drilled through `KvCanvas → CanvasStageFrame → KvFabricCanvas → BoardChrome`. A `useArtboardJump` hook turns a popover row into mode switch → select → centre → open pins, waiting for the surface to render. `KvGeneratorLayout` and `KvMotionEditor` only wire.

**Tech Stack:** Next.js 16 app router, React 19, TypeScript, Tailwind 3.4, TanStack Query v5, `@base-ui/react` (frndOS v2), PostHog (`posthog-js`), `bun test` (vitest-compatible API, jsdom preload), Testing Library.

**Spec:** `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md` — this plan implements **§6.1 (Part B)** under **§11** (frndOS components first, §11.2 map). Part A (§5) is already on the branch; Parts C and D are out of scope. Part B adds **no api** — it reads Part A's `GET v1/approval-requests` and `GET v1/approval-requests/preview` exactly as the binding contract block in `docs/superpowers/plans/2026-10-01-client-lane-kv-approval-requests-api.md` Task 1 describes (open requests first then newest; `approvals[].subject_key/version_id/thumbnail_url/status/superseded_by_request_number/pin_count/decisions`; preview `items/total/phases`).

## Global Constraints

- **Where to work:** worktree `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item`, branch `feature/daffa/vc-client-lane-multi-item` (unpushed; Part A is already committed on it — build on the ACTUAL code: `src/services/client-lane.ts`, `src/lib/client-lane/{requests,statusTone}.ts`, `src/components/client-lane/agency/{KvRequestForm,KvApprovalRequestsSection,useApproverEmails,StatusPill}.tsx`). Every command `cd`s into that literal path; agent shells reset cwd between calls.
- **Git:** use `/usr/bin/git` and `/usr/bin/grep` (an rtk hook rewrites plain `git`/`grep` output). Shell is zsh: put file lists in arrays (`F=(a b); npx eslint "${F[@]}"`) and quote globs (`--include='*.tsx'`). Commits `<type>(web): …` whose last line is `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. **Never push. Never `git stash`.** Commit with `/usr/bin/git commit -F - <<'EOF' … EOF`.
- **Tests:** `bun test <file>` — ONE file per invocation; never a directory, never `bunx vitest`. Query with `within(document.body)`, never `screen`. bun has no `vi.waitFor`, `vi.hoisted`, `vi.mocked` — use RTL `waitFor` and cast spies. Every test file stays < 45 KB. Import `"@testing-library/jest-dom/vitest"` at the top of component tests.
- **Mocks:** **never `vi.mock` a module.** Spy on the edges: `vi.spyOn(axiosInstance, "get"|"post")` (`import axiosInstance from "@/services/axios"`), `vi.spyOn(posthog, "capture")` (`import posthog from "posthog-js"`). `vi.restoreAllMocks()` in `beforeEach`. Consequence for code (from `KvSharePanel.test.tsx`'s existing module mocks, which also hit anything the panel renders — `KvRequestForm`, `KvApprovalRequestsSection`, and Task 4's `useRequestActions`): those files import nothing from `@/lib/featureFlags`, nothing from `@/lib/analytics/kv-generator-events`, and read toasts only as `useToastStore((s) => s.showToast)`.
- **Mutation check:** after a new test passes, break the rule exactly as the step says, run the file, watch the NAMED test fail, restore, watch it pass. If an expectation disagrees with the code, fix the expectation only when the code matches the spec.
- **Type / lint gate:** `npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"` stays at the baseline **895** (re-measured in Task 0); `npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "<touched paths>"` prints nothing; `npx eslint <touched files>` clean; `bunx prettier --write <touched files>` before each commit.
- **frndOS components first (spec §11):** before any UI task read `.agents/skills/frndos-ui/SKILL.md`, then `frndos-components-v2/SKILL.md`, `frndos-design-foundations/SKILL.md` (§Appearance Themes) and `frndos-rules/SKILL.md`. Priority **v2 → v1 → base → new v2 component** (new ones get `src/components/frndos/v2/<Name>.tsx`, an export in `v2/index.ts`, a story `src/components/frndos/stories/<Name>V2.stories.tsx` with `title: "FrndOS v2/<Name>"`, and a row in `.agents/skills/frndos-components-v2/SKILL.md`, all in the same task). §11.2 map for Part B: v2 `Button` (primary/secondary/text/icon), v2 `Popover` for the status popover and the form drop-down, v2 `Tooltip` for the compact icon, v2 `ItemRow` + v2 `ActionMenu` for request rows, the existing `StatusPill` wrapper (v1 `Label`) for every status pill, tone from the ONE map `src/lib/client-lane/statusTone.ts`.
- **One file never imports both `@/components/frndos` (v1) and `@/components/frndos/v2`.** v1 pieces stay inside their existing single-purpose wrappers (`StatusPill.tsx`, `PersonAvatar.tsx`, `DecideByField.tsx`). `KvCanvasTopNav.tsx` is a v1 file: it receives the v2 slot as a `ReactNode` prop and never imports v2.
- **Tokens only** on every line this plan writes: `text-text-inverse*` / `text-text-default*`, `text-textXs|textXsMedium|textSm|textSmMedium`, `rounded-full|2xl|xl|lg|md`, `bg-white/5|10|15`, `border-white/10|15`, hairlines `border-white/5`, `font-geist`, `transition-all duration-200 ease-out`, `focus-visible:ring-2 focus-visible:ring-white/40`. Never `text-[Npx]`, `rounded-[Npx]`, `px-[Npx]`, `w-[Npx]`, `text-white`, `text-gray-*`, or a new dark hex. Canvas surfaces use the theme-aware `frndos-float-panel` class (it already has Midnight / Aurora / Daylight values). Agency UI must read right in **Midnight, Aurora and Daylight**.
- **Toasts** `useToastStore((s) => s.showToast)` with positional args `(title, description, type)`. **Analytics** only through typed helpers in `src/lib/analytics/client-lane-events.ts` (never inline `posthog.capture`); every new event gets a Lark taxonomy row (Task 13 lists them).
- **Flag:** everything here sits behind `show-client-lane`. Hosts gate (`clientLaneOn` in the layout, `useClientLaneEnabled()` in the Motion editor); the new components never read the flag themselves.
- **Unchanged surfaces:** the Share dialog's behaviour (Part A) and the deck / plan share sheets must not change — `KvSharePanel.test.tsx` is the regression run for every task that touches what it renders.

## Review Focus

Five inputs the spec implies but its happy path does not exercise, most likely to bite first. Each has a named test in its owning task.

1. **The request form's "Decide by" calendar sits inside the slot's drop-down.** `DecideByField` is a Radix popover portalled to `<body>`; to Base UI a click on a date is an *outside press* (or a *focus-out*) and would close the form and lose the draft. → Task 6 `keepFormOpenOnPress` tests ("keeps the form open for a press inside the Decide-by calendar").
2. **An approved artboard that has since changed.** A board iterated to a new tip, a Motion size re-exported, or a Resize tile regenerated in place (same row id, new image) must not keep reading "Approved"; a pending or "New version asked" verdict stays until a newer request replaces it. → Task 1 `verdictChip` tests ("hides Approved once the board has a new tip", "hides Approved on a regenerated resize tile").
3. **Unmarking after tucking vs. a new version after tucking.** Unmarking one of the tucked artboards must NOT bring the tray back; marking something new, or a regenerated version of a tucked artboard, must. → Task 7 tests ("stays tucked when a ready artboard is unmarked", "comes back for a new version of a tucked artboard").
4. **A popover row whose artboard is on another tab, not drawn yet, or gone.** The jump must switch mode first and land only once the surface renders; an artboard that never appears gives up with a toast instead of yanking the camera seconds later. → Task 9 tests ("switches to Craft before landing on a resize tile", "gives up with a toast when the artboard never renders").
5. **Motion artboard keys whose ratio contains a colon** (`motion:{project}:9:16`). Routing must split on the first colon after the project id only. Also: a file whose only requests were withdrawn reads as "no request yet". → Task 1 tests ("keeps a colon inside a motion ratio", "treats a file with only withdrawn requests as never sent").

---

## File Structure

All paths relative to the web worktree root.

| File | Status | Responsibility |
|---|---|---|
| `docs/tracks/client-lane-multi-item.track.md` | modify | Part B section: plan link, baselines, checklist, session log |
| `src/lib/client-lane/canvasApproval.ts` | create | Pure Part B rules: artboard keys + routing, verdicts + chip text, slot state + chip text, jump plan, deep-link href/param, form prefill, "who · when" |
| `src/lib/client-lane/canvasApproval.test.ts` | create | Tests for the above |
| `src/lib/client-lane/requestFixtures.ts` | create | Test fixtures: `requestApproval`, `agencyRequest`, `previewItem`, `requestPreview` (no app code imports it) |
| `src/lib/client-lane/statusTone.ts` | modify | `TONE_DOT` — the status dot colour per `Label` variant |
| `src/lib/client-lane/readyTray.ts` | create | Tray set keys, subset-tuck rule, `sessionStorage` tuck + impression memory |
| `src/lib/analytics/client-lane-events.ts` | modify | `trackReadyTrayShown`, `trackReadyTrayTucked`, `trackStatusChipOpened`, `trackStatusRowJumped` |
| `src/components/frndos/v2/FloatingActionBar.tsx` | create | New v2: positionless floating glass action bar |
| `src/components/frndos/v2/CountBadge.tsx` | create | New v2: small count pill |
| `src/components/frndos/v2/index.ts` | modify | Export both |
| `src/components/frndos/stories/FloatingActionBarV2.stories.tsx`, `CountBadgeV2.stories.tsx` | create | Stories |
| `.agents/skills/frndos-components-v2/SKILL.md` | modify | Two component rows |
| `src/hooks/useKvReadyToShare.ts` | modify | Mark / unmark settle also invalidates the request queries |
| `src/components/studio/kv-generator/KvSharePanel.tsx` | modify | Closing the dialog invalidates the request queries |
| `src/components/client-lane/agency/useApproverEmails.ts` | modify | Optional initial emails |
| `src/components/client-lane/agency/KvRequestForm.tsx` | modify | `initialEmails`, `prefillMessage` (default message follows the phase pills until typed over) |
| `src/components/client-lane/agency/useRequestActions.tsx` | create | Copy link / Resend / Withdraw verbs + withdraw confirm, lifted from the section |
| `src/components/client-lane/agency/KvApprovalRequestsSection.tsx` | modify | Uses `useRequestActions` (behaviour unchanged) |
| `src/components/client-lane/agency/KvApprovalStatusList.tsx` (+ test) | create | Popover body: every request, verbs on the open one, one jump row per artboard |
| `src/components/client-lane/agency/KvClientApprovalSlot.tsx` (+ test) | create | Top-bar slot: Ready button / compact icon / status chip + `+n ready` / status popover / form drop-down / hover callbacks |
| `src/components/client-lane/agency/KvReadyForClientTray.tsx` (+ test) | create | The tray above the bottom nav |
| `src/components/studio/kv-generator/KvArtboardVerdictChip.tsx` (+ test) | create | Canvas verdict chip + `ArtboardVerdictsProvider` / `useArtboardVerdicts` |
| `src/components/studio/kv-generator/fabric/BoardChrome.tsx` | modify | Verdict chip beside the ready chip in the `readyChipAt` slot |
| `src/components/studio/kv-generator/KvResizeStripChrome.tsx` | modify | Verdict chip in the tile header, left of the ready chip |
| `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx` | modify | `verdict` prop; chip in the label row (ready chip classes unchanged) |
| `src/components/studio/kv-generator/focusCamera.ts` | modify | `KvFocusApi.selectSurface` |
| `src/components/studio/kv-generator/KvFabricCanvas.tsx` | modify | Publishes `selectSurface` |
| `src/components/studio/kv-generator/useArtboardJump.ts` (+ test) | create | Row → mode switch → select → centre → open pins, with give-up |
| `src/lib/studio/kv/readySetFrame.ts` (+ test) | create | Union of world rects; edge pointer for an off-screen set |
| `src/components/studio/kv-generator/KvReadySetFrame.tsx` | create | Hover frame around the ready set + edge pointer |
| `src/components/studio/kv-generator/KvCanvasTopNav.tsx` | modify | `clientSlot` prop, left of the avatars |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` | modify | Wires slot, compact, tray, frame, verdict provider, jump, `?focus_artboard=` |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` | modify | Slot in its top bar, verdicts on tiles, jump, `?focus_artboard=` |

---

### Task 0: Pre-flight — worktree, baselines, track file

**Files:**
- Modify: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:** none.

- [ ] **Step 1: Confirm the worktree**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git branch --show-current && /usr/bin/git status --short && /usr/bin/git log --oneline -1 && ls .env.local node_modules/.bin/next
```

Expected: `feature/daffa/vc-client-lane-multi-item`, an empty status, tip `752323bba` or newer, both paths listed. A dirty tree → stop and ask Daffa (never stash).

- [ ] **Step 2: Record the type baseline**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected `895`. Record whatever it prints; it is the number every later task compares against.

- [ ] **Step 3 (test): Record the regression baseline**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Record the pass/fail count. Failures here are pre-existing (Part A ran untested) — record them, do not fix them in this plan.

- [ ] **Step 4: Read the UI skills**

Read, in order: `.agents/skills/frndos-ui/SKILL.md`, `.agents/skills/frndos-components-v2/SKILL.md`, `.agents/skills/frndos-design-foundations/SKILL.md` (§Appearance Themes), `.agents/skills/frndos-rules/SKILL.md`, `.agents/skills/frndos-analytics-events/SKILL.md`.

- [ ] **Step 5: Add the Part B section to the track file**

Insert above `## Session Log` in `docs/tracks/client-lane-multi-item.track.md`:

```markdown
## Part B — canvas tray, top-bar slot, verdict chips (plan `docs/superpowers/plans/2026-10-01-client-lane-kv-approval-part-b-web.md`)

Part B base: <tip from Step 1>. Baselines (Task 0): tsc <Step 2 number>; KvSharePanel.test <Step 3 result>.

- [ ] Task 0: baselines, this section
- [ ] Task 1: pure rules (`canvasApproval.ts`), fixtures, dot tone, analytics helpers
- [ ] Task 2: v2 FloatingActionBar + CountBadge
- [ ] Task 3: query freshness + request form prefill
- [ ] Task 4: `useRequestActions` lifted from the section
- [ ] Task 5: KvApprovalStatusList
- [ ] Task 6: KvClientApprovalSlot
- [ ] Task 7: KvReadyForClientTray
- [ ] Task 8: verdict chips on boards, tiles, motion tiles
- [ ] Task 9: focus API `selectSurface` + `useArtboardJump`
- [ ] Task 10: hover frame + edge pointer
- [ ] Task 11: KvGeneratorLayout wiring
- [ ] Task 12: KvMotionEditor wiring
- [ ] Task 13: gates, manual smoke, tri-mode, Lark taxonomy
```

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add docs/tracks/client-lane-multi-item.track.md && /usr/bin/git commit -F - <<'EOF'
docs(web): track KV approval requests Part B — plan and baselines

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 1: Pure rules, fixtures, dot tone, analytics helpers

**Files:**
- Create: `src/lib/client-lane/canvasApproval.ts`
- Create: `src/lib/client-lane/requestFixtures.ts`
- Create: `src/lib/client-lane/canvasApproval.test.ts`
- Modify: `src/lib/client-lane/statusTone.ts` (append)
- Modify: `src/lib/analytics/client-lane-events.ts` (append to the agency section)

**Interfaces:**
- Consumes: `AgencyRequest`, `AgencyRequestApproval`, `ApprovalRequestPreviewItem`, `ApprovalRequestPreview` (`@/services/client-lane`); `plural`, `requestArtboardTotal` (`./requests`); `STATUS_TONE`, `Tone` (`./statusTone`); `shortWhen` (`./format`); `KV_SHARE_PHASES`, `KV_SHARE_PHASE_LABEL`, `KvSharePhase` (`@/types/kv/share-link`).
- Produces (later tasks rely on these exact names):
  - `type ParsedSubjectKey = { kind: "board"; chainId } | { kind: "resize"; rowId } | { kind: "motion"; projectId; ratio }`; `parseSubjectKey(key: string): ParsedSubjectKey | null`
  - `boardSubjectKey(board: { id: string; version_ids?: string[] | null }): string`, `resizeSubjectKey(rowId: string): string`, `motionSubjectKey(projectId: string, ratio: string): string`
  - `interface ArtboardVerdict { approvalId; requestNumber; status: "pending" | "approved" | "approved_with_changes" | "changes_required"; versionId; thumbnailUrl: string | null; pinCount }`; `artboardVerdicts(requests: AgencyRequest[]): Map<string, ArtboardVerdict>`
  - `type VerdictChipState = "waiting" | "feedback" | "approved" | "approved_with_fixes" | "new_version_asked"`; `interface VerdictChipView { state; text: string; variant: LabelVariant }`; `interface CurrentArtboardVersion { versionId: string | null; imageUrl?: string | null }`; `verdictChip(v: ArtboardVerdict | null | undefined, current: CurrentArtboardVersion): VerdictChipView | null`
  - `type SlotState = { kind: "hidden" } | { kind: "ready"; readyTotal } | { kind: "status"; request: AgencyRequest; open: boolean; text: string; shortText: string; variant: LabelVariant; readyTotal }`; `slotStateOf(requests: AgencyRequest[], readyTotal: number): SlotState`
  - `requestDefaultMessage(items: Pick<ApprovalRequestPreviewItem, "phase">[]): string`; `lastRequestEmails(requests: AgencyRequest[]): string[]`; `artboardWho(a: Pick<AgencyRequestApproval, "decisions">): string | null`
  - `interface ArtboardJumpTarget { subjectKey: string; phase: KvSharePhase; versionId: string | null }`; `type ArtboardJumpPlan = { kind: "surface"; mode: "sketch" | "craft"; surfaceId: string; pinVersionId: string } | { kind: "motion"; projectId: string; ratio: string } | { kind: "none" }`; `planArtboardJump(target, resolveTip: (generationId: string) => string | null): ArtboardJumpPlan`
  - `artboardHref({ brandId, fileId, subjectKey, phase }): string`; `focusParamOf(params: { get(name: string): string | null } | null | undefined): ArtboardJumpTarget | null`
  - `statusTone.ts`: `TONE_DOT: Record<LabelVariant, string>`
  - `client-lane-events.ts`: `type ApprovalSurface = "canvas" | "motion"`; `trackReadyTrayShown({ ready_total })`; `trackReadyTrayTucked({ ready_total, method: "button" | "canvas" })`; `trackStatusChipOpened({ surface, request_status, request_count, ready_total })`; `trackStatusRowJumped({ surface, phase, status, replaced })`
  - Fixtures: `requestApproval(o?)`, `agencyRequest(o?)`, `previewItem(o?)`, `requestPreview(items, o?)`

- [ ] **Step 1: Fixtures**

Create `src/lib/client-lane/requestFixtures.ts`:

```ts
/**
 * Fixtures for the KV approval-request suites (Part B). Not a test file —
 * bun never collects it — and no app code imports it.
 */
import type {
  AgencyRequest,
  AgencyRequestApproval,
  ApprovalRequestPreview,
  ApprovalRequestPreviewItem,
} from "@/services/client-lane";
import { KV_SHARE_PHASES } from "@/types/kv/share-link";

export function requestApproval(
  overrides: Partial<AgencyRequestApproval> = {}
): AgencyRequestApproval {
  return {
    id: "apr1",
    subject_key: "board:g0",
    phase: "craft",
    label: "Craft · Hero",
    round: 1,
    version_id: "g1",
    thumbnail_url: "https://cdn.test/g1.png",
    status: "pending",
    superseded_by_request_number: null,
    pin_count: 0,
    decisions: [],
    ...overrides,
  };
}

export function agencyRequest(
  overrides: Partial<AgencyRequest> = {}
): AgencyRequest {
  return {
    id: "req1",
    number: 1,
    status: "pending",
    policy: "optional",
    message: null,
    sent_at: "2026-10-01T08:00:00.000Z",
    decide_by: null,
    deferred_until: null,
    deferred_note: null,
    resolved_at: null,
    created_at: "2026-10-01T08:00:00.000Z",
    share_url: "https://app.test/s/tok1",
    share_link_active: true,
    counts: {
      approved: 0,
      approved_with_changes: 0,
      changes_required: 0,
      pending: 1,
      superseded: 0,
    },
    approvers: [],
    approvals: [requestApproval()],
    ...overrides,
  };
}

export function previewItem(
  overrides: Partial<ApprovalRequestPreviewItem> = {}
): ApprovalRequestPreviewItem {
  return {
    subject_key: "board:g0",
    phase: "craft",
    label: "Craft · Hero",
    version_id: "g1",
    thumbnail_url: "https://cdn.test/g1.png",
    replaces: null,
    ...overrides,
  };
}

export function requestPreview(
  items: ApprovalRequestPreviewItem[],
  overrides: Partial<ApprovalRequestPreview> = {}
): ApprovalRequestPreview {
  return {
    phases: KV_SHARE_PHASES.map((phase) => ({
      phase,
      count: items.filter((i) => i.phase === phase).length,
    })).filter((p) => p.count > 0),
    items,
    already_approved: [],
    waiting: [],
    total: items.length,
    ...overrides,
  };
}
```

- [ ] **Step 2: Dot tone**

Append to `src/lib/client-lane/statusTone.ts`:

```ts
/**
 * The status dot on canvas chrome and the top-bar chip (spec 2026-10-01
 * §6.1 "each takes the colour of its status pill"). Keyed by the SAME
 * `Label` variant `STATUS_TONE` assigns, so a dot and a pill for one status
 * can never disagree. Palette classes, not hex: they flip with the theme
 * sweep like `Label`'s own.
 */
export const TONE_DOT: Record<LabelVariant, string> = {
  success: "bg-emerald-500",
  alert: "bg-yellow-400",
  error: "bg-red-500",
  neutral: "bg-white/40",
  translucent: "bg-white/40",
};
```

- [ ] **Step 3 (test): Write the failing tests**

Create `src/lib/client-lane/canvasApproval.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  artboardHref,
  artboardVerdicts,
  artboardWho,
  boardSubjectKey,
  focusParamOf,
  lastRequestEmails,
  parseSubjectKey,
  planArtboardJump,
  requestDefaultMessage,
  slotStateOf,
  verdictChip,
  type ArtboardVerdict,
} from "./canvasApproval";
import {
  agencyRequest,
  previewItem,
  requestApproval,
} from "./requestFixtures";

const six = (status: "pending" | "approved" | "changes_required") =>
  Array.from({ length: 6 }, (_, i) =>
    requestApproval({
      id: `a${i}`,
      subject_key: `resize:r${i}`,
      phase: "resize",
      version_id: `r${i}`,
      status,
    })
  );

const counts = (o: Partial<ReturnType<typeof agencyRequest>["counts"]>) => ({
  approved: 0,
  approved_with_changes: 0,
  changes_required: 0,
  pending: 0,
  superseded: 0,
  ...o,
});

const dina = {
  name: "Dina",
  email: "dina@brand.test",
  user_id: null,
  personal_url: null,
  decided: false,
};

describe("slotStateOf", () => {
  it("offers Ready for client when nothing was sent and something is ready", () => {
    expect(slotStateOf([], 6)).toEqual({ kind: "ready", readyTotal: 6 });
  });

  it("hides when nothing was sent and nothing is ready", () => {
    expect(slotStateOf([], 0)).toEqual({ kind: "hidden" });
  });

  it("says who an open request waits on and how far it got", () => {
    const state = slotStateOf(
      [
        agencyRequest({
          approvers: [dina],
          approvals: six("pending"),
          counts: counts({ pending: 6 }),
        }),
      ],
      0
    );
    expect(state).toMatchObject({
      kind: "status",
      open: true,
      text: "Waiting on Dina · 0/6",
      shortText: "0/6",
      variant: "alert",
    });
  });

  it("names one undecided approver and counts the rest", () => {
    const state = slotStateOf(
      [
        agencyRequest({
          approvers: [dina, { ...dina, name: "Raka", email: "r@b.test" }],
          approvals: six("pending"),
          counts: counts({ pending: 5, approved: 1 }),
        }),
      ],
      0
    );
    expect(state).toMatchObject({ text: "Waiting on Dina +1 · 1/6" });
  });

  it("lets an open request win over a newer closed one", () => {
    const open = agencyRequest({
      id: "q1",
      number: 1,
      approvals: six("pending"),
      counts: counts({ pending: 6 }),
    });
    const closed = agencyRequest({
      id: "q2",
      number: 2,
      status: "approved",
      approvals: six("approved"),
      counts: counts({ approved: 6 }),
    });
    const state = slotStateOf([open, closed], 2);
    expect(state).toMatchObject({
      kind: "status",
      open: true,
      text: "Waiting · 0/6",
      readyTotal: 2,
    });
  });

  it("shows the last result when nothing is open", () => {
    const approved = agencyRequest({
      number: 1,
      status: "approved",
      approvals: six("approved"),
      counts: counts({ approved: 6 }),
    });
    expect(slotStateOf([approved], 0)).toMatchObject({
      text: "Approved · 6/6",
      variant: "success",
    });
    const changes = agencyRequest({
      number: 2,
      status: "changes_required",
      approvals: six("approved"),
      counts: counts({ approved: 5, changes_required: 1 }),
    });
    expect(slotStateOf([approved, changes], 0)).toMatchObject({
      text: "Changes · 5/6",
      variant: "error",
    });
  });

  it("treats a file with only withdrawn requests as never sent", () => {
    const withdrawn = agencyRequest({ status: "not_relevant" });
    expect(slotStateOf([withdrawn], 3)).toEqual({
      kind: "ready",
      readyTotal: 3,
    });
  });
});

describe("artboardVerdicts + verdictChip", () => {
  it("takes each artboard's verdict from its newest request", () => {
    const older = agencyRequest({
      id: "q1",
      number: 1,
      approvals: [
        requestApproval({
          id: "old",
          status: "not_relevant",
          superseded_by_request_number: 2,
        }),
      ],
    });
    const newer = agencyRequest({
      id: "q2",
      number: 2,
      approvals: [requestApproval({ id: "new", version_id: "g3" })],
    });
    const map = artboardVerdicts([older, newer]);
    expect(map.get("board:g0")).toMatchObject({
      approvalId: "new",
      requestNumber: 2,
      versionId: "g3",
    });
  });

  it("gives a withdrawn artboard no verdict", () => {
    const map = artboardVerdicts([
      agencyRequest({
        number: 1,
        approvals: [requestApproval({ status: "approved" })],
      }),
      agencyRequest({
        id: "q2",
        number: 2,
        status: "not_relevant",
        approvals: [requestApproval({ id: "w", status: "not_relevant" })],
      }),
    ]);
    expect(map.has("board:g0")).toBe(false);
  });

  const verdict = (o: Partial<ArtboardVerdict> = {}): ArtboardVerdict => ({
    approvalId: "a",
    requestNumber: 1,
    status: "pending",
    versionId: "g1",
    thumbnailUrl: null,
    pinCount: 0,
    ...o,
  });

  it("reads every state with its pin count", () => {
    const cur = { versionId: "g1" };
    expect(verdictChip(verdict({}), cur)).toEqual({
      state: "waiting",
      text: "Waiting",
      variant: "alert",
    });
    expect(verdictChip(verdict({ pinCount: 2 }), cur)?.text).toBe(
      "Feedback, no decision yet · 2 pins"
    );
    expect(verdictChip(verdict({ status: "approved" }), cur)?.text).toBe(
      "Approved"
    );
    expect(
      verdictChip(verdict({ status: "approved_with_changes" }), cur)
    ).toMatchObject({ state: "approved_with_fixes", variant: "success" });
    expect(
      verdictChip(verdict({ status: "changes_required", pinCount: 5 }), cur)
    ).toEqual({
      state: "new_version_asked",
      text: "New version asked · 5 pins",
      variant: "error",
    });
    expect(verdictChip(null, cur)).toBeNull();
  });

  it("hides Approved once the board has a new tip", () => {
    expect(
      verdictChip(verdict({ status: "approved" }), { versionId: "g2" })
    ).toBeNull();
  });

  it("hides Approved on a regenerated resize tile", () => {
    const v = verdict({
      status: "approved",
      versionId: "r1",
      thumbnailUrl: "https://cdn.test/r1-a.png",
    });
    expect(
      verdictChip(v, { versionId: "r1", imageUrl: "https://cdn.test/r1-b.png" })
    ).toBeNull();
    expect(
      verdictChip(v, { versionId: "r1", imageUrl: "https://cdn.test/r1-a.png" })
    ).toMatchObject({ state: "approved" });
  });

  it("keeps New version asked after the artboard moved on", () => {
    expect(
      verdictChip(verdict({ status: "changes_required" }), { versionId: "g9" })
    ).toMatchObject({ state: "new_version_asked" });
  });
});

describe("artboard keys and jumps", () => {
  it("keeps a colon inside a motion ratio", () => {
    expect(parseSubjectKey("motion:01P:9:16")).toEqual({
      kind: "motion",
      projectId: "01P",
      ratio: "9:16",
    });
    expect(parseSubjectKey("resize:r1")).toEqual({
      kind: "resize",
      rowId: "r1",
    });
    expect(parseSubjectKey("board:")).toBeNull();
    expect(parseSubjectKey("garbage")).toBeNull();
  });

  it("keys a board by its chain's first generation, else its tip", () => {
    expect(boardSubjectKey({ id: "g3", version_ids: ["g0", "g3"] })).toBe(
      "board:g0"
    );
    expect(boardSubjectKey({ id: "g3", version_ids: null })).toBe("board:g3");
  });

  it("plans a board jump onto the chain's current tip and mode", () => {
    const tips: Record<string, string> = { g0: "g3", g3: "g3" };
    expect(
      planArtboardJump(
        { subjectKey: "board:g0", phase: "sketch", versionId: "g1" },
        (id) => tips[id] ?? null
      )
    ).toEqual({
      kind: "surface",
      mode: "sketch",
      surfaceId: "g3",
      pinVersionId: "g1",
    });
  });

  it("plans resize tiles on Craft and motion clips off-canvas", () => {
    const none = () => null;
    expect(
      planArtboardJump(
        { subjectKey: "resize:r1", phase: "resize", versionId: "r1" },
        none
      )
    ).toEqual({
      kind: "surface",
      mode: "craft",
      surfaceId: "r1",
      pinVersionId: "r1",
    });
    expect(
      planArtboardJump(
        { subjectKey: "motion:01P:9:16", phase: "motion", versionId: "m2" },
        none
      )
    ).toEqual({ kind: "motion", projectId: "01P", ratio: "9:16" });
  });

  it("links to an artboard and reads the link back", () => {
    const href = artboardHref({
      brandId: "b1",
      fileId: "f1",
      subjectKey: "resize:r1",
      phase: "resize",
    });
    expect(href).toBe(
      "/brands/b1/studio/kv-generator/f1?focus_artboard=resize%3Ar1&focus_phase=resize"
    );
    expect(
      artboardHref({
        brandId: "b1",
        fileId: "f1",
        subjectKey: "motion:01P:9:16",
        phase: "motion",
      })
    ).toBe(
      "/brands/b1/studio/kv-generator/f1/motion/01P?focus_artboard=motion%3A01P%3A9%3A16"
    );
    const params = new URLSearchParams(href.split("?")[1]);
    expect(focusParamOf(params)).toEqual({
      subjectKey: "resize:r1",
      phase: "resize",
      versionId: null,
    });
    expect(focusParamOf(new URLSearchParams("focus_artboard=nope"))).toBeNull();
  });
});

describe("form prefill and rows", () => {
  it("writes the default message from what is selected", () => {
    expect(
      requestDefaultMessage([
        previewItem({ phase: "resize" }),
        previewItem({ phase: "craft" }),
        previewItem({ phase: "resize" }),
      ])
    ).toBe("3 artboards ready: Craft 1 · Resize 2");
    expect(requestDefaultMessage([])).toBe("");
  });

  it("prefills the approvers of the file's newest request", () => {
    expect(
      lastRequestEmails([
        agencyRequest({ number: 1, approvers: [dina] }),
        agencyRequest({
          number: 2,
          approvers: [{ ...dina, email: "raka@brand.test" }],
        }),
      ])
    ).toEqual(["raka@brand.test"]);
    expect(lastRequestEmails([])).toEqual([]);
  });

  it("says who decided an artboard, never a deferral", () => {
    const decision = {
      id: "d1",
      actor: "Dina",
      outcome: "approved" as const,
      note: null,
      pins: [],
      decided_at: null,
      advisory: false,
      deferred_until: null,
    };
    expect(artboardWho({ decisions: [decision] })).toBe("Dina");
    expect(
      artboardWho({
        decisions: [{ ...decision, outcome: "deferred" as const }],
      })
    ).toBeNull();
  });
});
```

- [ ] **Step 4 (test): Run — fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/canvasApproval.test.ts
```

Expected: FAIL — `Cannot find module './canvasApproval'`.

- [ ] **Step 5: Implement**

Create `src/lib/client-lane/canvasApproval.ts`:

```ts
/**
 * Part B of KV approval requests (spec 2026-10-01 §6.1) — the pure rules
 * behind the canvas: what the top-bar slot shows, what an artboard's
 * verdict chip says, where a popover row jumps, and the request form's
 * prefill. No React, no api; type-only imports from the service.
 *
 * Artboard keys are identities (contract: "compare it, never parse it").
 * They are parsed here ONLY to route a jump — never to display anything.
 */
import type { LabelVariant } from "@/components/frndos/Label";
import type {
  AgencyRequest,
  AgencyRequestApproval,
  ApprovalRequestPreviewItem,
} from "@/services/client-lane";
import {
  KV_SHARE_PHASES,
  KV_SHARE_PHASE_LABEL,
  type KvSharePhase,
} from "@/types/kv/share-link";

import { shortWhen } from "./format";
import { plural, requestArtboardTotal } from "./requests";
import { STATUS_TONE } from "./statusTone";

/* ── Artboard keys ─────────────────────────────────────────────────────── */

export type ParsedSubjectKey =
  | { kind: "board"; chainId: string }
  | { kind: "resize"; rowId: string }
  | { kind: "motion"; projectId: string; ratio: string };

export function parseSubjectKey(key: string): ParsedSubjectKey | null {
  if (key.startsWith("board:") && key.length > "board:".length) {
    return { kind: "board", chainId: key.slice("board:".length) };
  }
  if (key.startsWith("resize:") && key.length > "resize:".length) {
    return { kind: "resize", rowId: key.slice("resize:".length) };
  }
  if (key.startsWith("motion:")) {
    // The ratio is a tile key and may itself hold a colon ("9:16"); the
    // project id (a ULID) never does, so split on the FIRST colon only.
    const rest = key.slice("motion:".length);
    const cut = rest.indexOf(":");
    if (cut > 0 && cut < rest.length - 1) {
      return {
        kind: "motion",
        projectId: rest.slice(0, cut),
        ratio: rest.slice(cut + 1),
      };
    }
  }
  return null;
}

/** `board:{first generation of the chain}`, else the tip (contract §4.2). */
export function boardSubjectKey(board: {
  id: string;
  version_ids?: string[] | null;
}): string {
  return `board:${board.version_ids?.[0] ?? board.id}`;
}

export const resizeSubjectKey = (rowId: string): string => `resize:${rowId}`;

export const motionSubjectKey = (projectId: string, ratio: string): string =>
  `motion:${projectId}:${ratio}`;

/* ── Verdicts ──────────────────────────────────────────────────────────── */

export interface ArtboardVerdict {
  approvalId: string;
  requestNumber: number;
  status: "pending" | "approved" | "approved_with_changes" | "changes_required";
  /** The version the client was shown. */
  versionId: string;
  /** The snapshot's image — the only way to tell a regenerated resize tile
   *  (same row id) from the one that was approved. */
  thumbnailUrl: string | null;
  pinCount: number;
}

/**
 * Each artboard's verdict, from the NEWEST request that holds it. A newer
 * request supersedes an older one for the same key, so the first hit in
 * newest-first order is the live one; when that one was withdrawn the
 * artboard has no verdict (an older answer is not resurrected).
 */
export function artboardVerdicts(
  requests: AgencyRequest[]
): Map<string, ArtboardVerdict> {
  const out = new Map<string, ArtboardVerdict>();
  const seen = new Set<string>();
  const newestFirst = [...requests].sort((a, b) => b.number - a.number);
  for (const request of newestFirst) {
    for (const a of request.approvals) {
      if (seen.has(a.subject_key)) continue;
      seen.add(a.subject_key);
      if (a.status === "not_relevant") continue;
      out.set(a.subject_key, {
        approvalId: a.id,
        requestNumber: request.number,
        status: a.status,
        versionId: a.version_id,
        thumbnailUrl: a.thumbnail_url,
        pinCount: a.pin_count,
      });
    }
  }
  return out;
}

export type VerdictChipState =
  | "waiting"
  | "feedback"
  | "approved"
  | "approved_with_fixes"
  | "new_version_asked";

export interface VerdictChipView {
  state: VerdictChipState;
  text: string;
  variant: LabelVariant;
}

/** What the canvas currently renders for that artboard. `null` = unknown
 *  (never hides a verdict). */
export interface CurrentArtboardVersion {
  versionId: string | null;
  imageUrl?: string | null;
}

function approvedOnOtherArtwork(
  v: ArtboardVerdict,
  current: CurrentArtboardVersion
): boolean {
  if (current.versionId != null && current.versionId !== v.versionId) {
    return true;
  }
  return Boolean(
    v.thumbnailUrl && current.imageUrl && v.thumbnailUrl !== current.imageUrl
  );
}

/**
 * The chip on an artboard (spec §6.1). Pending and "New version asked" stay
 * until a newer request replaces them — they describe the conversation, not
 * the pixels. "Approved" is about the pixels: once the artboard renders
 * something else (a new tip, a re-export, a regenerated tile) it is gone.
 */
export function verdictChip(
  v: ArtboardVerdict | null | undefined,
  current: CurrentArtboardVersion
): VerdictChipView | null {
  if (!v) return null;
  const variant = STATUS_TONE[v.status].variant;
  const pins = v.pinCount > 0 ? ` · ${plural(v.pinCount, "pin")}` : "";
  switch (v.status) {
    case "pending":
      return v.pinCount > 0
        ? {
            state: "feedback",
            text: `Feedback, no decision yet${pins}`,
            variant,
          }
        : { state: "waiting", text: "Waiting", variant };
    case "changes_required":
      return {
        state: "new_version_asked",
        text: `New version asked${pins}`,
        variant,
      };
    case "approved":
    case "approved_with_changes":
      if (approvedOnOtherArtwork(v, current)) return null;
      return v.status === "approved"
        ? { state: "approved", text: "Approved", variant }
        : { state: "approved_with_fixes", text: "Approved with fixes", variant };
  }
}

/* ── Top-bar slot ──────────────────────────────────────────────────────── */

export type SlotState =
  | { kind: "hidden" }
  | { kind: "ready"; readyTotal: number }
  | {
      kind: "status";
      request: AgencyRequest;
      open: boolean;
      /** "Waiting on Dina · 0/6", "Approved · 6/6", "Changes · 5/6". */
      text: string;
      /** The fraction alone, for the compact bar. */
      shortText: string;
      variant: LabelVariant;
      /** Something new to send on top — the chip's `+n ready`. */
      readyTotal: number;
    };

/**
 * Withdrawn requests do not count: a file whose every request was withdrawn
 * reads as "nothing sent yet". An open request wins (the newest open one);
 * otherwise the newest result shows.
 */
export function slotStateOf(
  requests: AgencyRequest[],
  readyTotal: number
): SlotState {
  const live = requests
    .filter((r) => r.status !== "not_relevant")
    .sort((a, b) => b.number - a.number);
  if (live.length === 0) {
    return readyTotal > 0 ? { kind: "ready", readyTotal } : { kind: "hidden" };
  }
  const open = live.find((r) => r.status === "pending") ?? null;
  const request = open ?? live[0];
  const total = requestArtboardTotal(request);
  let lead: string;
  let fraction: string;
  if (open) {
    fraction = `${total - open.counts.pending}/${total}`;
    const waiting = open.approvers
      .filter((a) => !a.decided)
      .map((a) => a.name || a.email);
    lead =
      waiting.length === 0
        ? "Waiting"
        : waiting.length === 1
          ? `Waiting on ${waiting[0]}`
          : `Waiting on ${waiting[0]} +${waiting.length - 1}`;
  } else {
    const approved =
      request.counts.approved + request.counts.approved_with_changes;
    fraction = `${approved}/${total}`;
    lead = request.status === "changes_required" ? "Changes" : "Approved";
  }
  return {
    kind: "status",
    request,
    open: open !== null,
    text: `${lead} · ${fraction}`,
    shortText: fraction,
    variant: STATUS_TONE[request.status].variant,
    readyTotal,
  };
}

/* ── Request form prefill ──────────────────────────────────────────────── */

/** `{n} artboards ready: Craft 1 · Resize 5` (spec §6.1). */
export function requestDefaultMessage(
  items: Pick<ApprovalRequestPreviewItem, "phase">[]
): string {
  if (items.length === 0) return "";
  const parts = KV_SHARE_PHASES.map(
    (phase) => [phase, items.filter((i) => i.phase === phase).length] as const
  )
    .filter(([, n]) => n > 0)
    .map(([phase, n]) => `${KV_SHARE_PHASE_LABEL[phase]} ${n}`);
  return `${plural(items.length, "artboard")} ready: ${parts.join(" · ")}`;
}

/** The approvers of the file's newest request (any status). */
export function lastRequestEmails(requests: AgencyRequest[]): string[] {
  const newest = [...requests].sort((a, b) => b.number - a.number)[0];
  return newest ? newest.approvers.map((a) => a.email).filter(Boolean) : [];
}

/** "Dina · 14:11" — the latest decision on an artboard; a deferral is
 *  request-level and never names an artboard. */
export function artboardWho(
  a: Pick<AgencyRequestApproval, "decisions">
): string | null {
  const latest = [...a.decisions]
    .reverse()
    .find((d) => d.outcome !== "deferred");
  if (!latest) return null;
  const when = shortWhen(latest.decided_at);
  return when ? `${latest.actor} · ${when}` : latest.actor;
}

/* ── Jumps ─────────────────────────────────────────────────────────────── */

export interface ArtboardJumpTarget {
  subjectKey: string;
  phase: KvSharePhase;
  /** The version the client saw — where its pins hang. */
  versionId: string | null;
}

export type ArtboardJumpPlan =
  | {
      kind: "surface";
      mode: "sketch" | "craft";
      /** A board tip or a strip tile row id. */
      surfaceId: string;
      /** The version whose pins the Comments dock opens. */
      pinVersionId: string;
    }
  | { kind: "motion"; projectId: string; ratio: string }
  | { kind: "none" };

/**
 * Where a row goes. Boards land on their chain's CURRENT tip (the board may
 * have been iterated since it was sent); resize tiles live in Craft's strip;
 * motion clips are in the Motion editor, off this canvas.
 */
export function planArtboardJump(
  target: ArtboardJumpTarget,
  resolveTip: (generationId: string) => string | null
): ArtboardJumpPlan {
  const parsed = parseSubjectKey(target.subjectKey);
  if (!parsed) return { kind: "none" };
  if (parsed.kind === "motion") {
    return {
      kind: "motion",
      projectId: parsed.projectId,
      ratio: parsed.ratio,
    };
  }
  if (parsed.kind === "resize") {
    return {
      kind: "surface",
      mode: "craft",
      surfaceId: parsed.rowId,
      pinVersionId: target.versionId ?? parsed.rowId,
    };
  }
  const surfaceId =
    resolveTip(parsed.chainId) ??
    (target.versionId ? resolveTip(target.versionId) : null) ??
    target.versionId ??
    parsed.chainId;
  return {
    kind: "surface",
    mode: target.phase === "sketch" ? "sketch" : "craft",
    surfaceId,
    pinVersionId: target.versionId ?? surfaceId,
  };
}

const PHASE_OF_KIND: Record<ParsedSubjectKey["kind"], KvSharePhase> = {
  board: "craft",
  resize: "resize",
  motion: "motion",
};

/** A link to an artboard from the other editor (`?focus_artboard=`). */
export function artboardHref(input: {
  brandId: string;
  fileId: string;
  subjectKey: string;
  phase: KvSharePhase;
}): string {
  const base = `/brands/${input.brandId}/studio/kv-generator/${input.fileId}`;
  const parsed = parseSubjectKey(input.subjectKey);
  const query = new URLSearchParams({ focus_artboard: input.subjectKey });
  if (parsed?.kind === "motion") {
    return `${base}/motion/${parsed.projectId}?${query.toString()}`;
  }
  query.set("focus_phase", input.phase);
  return `${base}?${query.toString()}`;
}

/** Reads `?focus_artboard=&focus_phase=` back; null for anything invalid. */
export function focusParamOf(
  params: { get(name: string): string | null } | null | undefined
): ArtboardJumpTarget | null {
  const subjectKey = params?.get("focus_artboard") ?? null;
  if (!subjectKey) return null;
  const parsed = parseSubjectKey(subjectKey);
  if (!parsed) return null;
  const raw = params?.get("focus_phase") ?? null;
  const phase = KV_SHARE_PHASES.includes(raw as KvSharePhase)
    ? (raw as KvSharePhase)
    : PHASE_OF_KIND[parsed.kind];
  return { subjectKey, phase, versionId: null };
}
```

- [ ] **Step 6 (test): Run — passes**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/canvasApproval.test.ts
```

Expected: PASS, every test.

- [ ] **Step 7 (test): Mutation checks**

One at a time, each restored before the next:
1. In `slotStateOf`, delete `.filter((r) => r.status !== "not_relevant")` → "treats a file with only withdrawn requests as never sent" fails.
2. In `verdictChip`, replace `if (approvedOnOtherArtwork(v, current)) return null;` with nothing → "hides Approved once the board has a new tip" and "hides Approved on a regenerated resize tile" fail.
3. In `parseSubjectKey`, change `rest.indexOf(":")` to `rest.lastIndexOf(":")` → "keeps a colon inside a motion ratio" fails.
4. In `artboardVerdicts`, swap the sort to `a.number - b.number` → "takes each artboard's verdict from its newest request" fails.

- [ ] **Step 8: Analytics helpers**

In `src/lib/analytics/client-lane-events.ts`, add `ApprovalStatus` to the existing type import from `@/lib/client-lane/types`, then append at the end of the `/* ── Agency side — KV approval requests … */` block (after `trackApprovalRequestResendFailed`):

```ts
/* ── Agency side — canvas (spec 2026-10-01 §6.1, Part B) ───────────────── */

/** Which editor hosts the top-bar slot. */
export type ApprovalSurface = "canvas" | "motion";

/** The ready tray appeared for a set of ready artboards this session has
 *  not shown yet (once per set — an impression, not a render). */
export const trackReadyTrayShown = (props: {
  /** Artboards in the set: what a request would hold now. */
  ready_total: number;
}) => safeCapture("client_lane.ready_tray_shown", props);

/** The tray was put away until something new is marked. */
export const trackReadyTrayTucked = (props: {
  ready_total: number;
  /** `button` = its "–"; `canvas` = the next press on the canvas. */
  method: "button" | "canvas";
}) => safeCapture("client_lane.ready_tray_tucked", props);

/** The top-bar status chip opened its popover. */
export const trackStatusChipOpened = (props: {
  surface: ApprovalSurface;
  /** The request the chip describes (the open one, else the newest). */
  request_status: ApprovalStatus;
  /** Every request on the file, withdrawn included. */
  request_count: number;
  /** New artboards ready on top (the chip's `+n ready`). */
  ready_total: number;
}) => safeCapture("client_lane.status_chip_opened", props);

/** An artboard row in the status popover took the canvas to it. */
export const trackStatusRowJumped = (props: {
  surface: ApprovalSurface;
  phase: KvSharePhase;
  status: ApprovalStatus;
  /** The row was superseded by a newer request. */
  replaced: boolean;
}) => safeCapture("client_lane.status_row_jumped", props);
```

- [ ] **Step 9: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/client-lane/canvasApproval.ts src/lib/client-lane/canvasApproval.test.ts src/lib/client-lane/requestFixtures.ts src/lib/client-lane/statusTone.ts src/lib/analytics/client-lane-events.ts) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "canvasApproval|requestFixtures|statusTone|client-lane-events"
```

Expected: eslint clean, the tsc grep prints nothing.

- [ ] **Step 10: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/client-lane/canvasApproval.ts src/lib/client-lane/canvasApproval.test.ts src/lib/client-lane/requestFixtures.ts src/lib/client-lane/statusTone.ts src/lib/analytics/client-lane-events.ts && /usr/bin/git commit -F - <<'EOF'
feat(web): Part B rules — slot state, artboard verdicts, jump plan, prefill

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 2: New v2 components — `FloatingActionBar` and `CountBadge`

Ruling (§11.2): v1 `FloatingSelectionBar` does not fit — it is `fixed bottom-[70px]`, measures `[data-shell-content-card]` and falls back to viewport centring, while the KV canvas lives outside the SidebarShell and is narrowed from the right by the comment dock and a docked chat. v2 `DropSuggestionBar` does not fit either — it steals focus on mount and binds a global Escape, wrong for a tray that appears every time something is marked. No badge exists in v1 or v2. So: two new, positionless v2 pieces.

**Files:**
- Create: `src/components/frndos/v2/FloatingActionBar.tsx`
- Create: `src/components/frndos/v2/CountBadge.tsx`
- Modify: `src/components/frndos/v2/index.ts`
- Create: `src/components/frndos/stories/FloatingActionBarV2.stories.tsx`, `src/components/frndos/stories/CountBadgeV2.stories.tsx`
- Modify: `.agents/skills/frndos-components-v2/SKILL.md`

**Interfaces:**
- Produces: `FloatingActionBar` (`{ ariaLabel: string; children: ReactNode; className?: string }`, forwards a ref to its root `div[role=region]`); `CountBadge` (`{ count: number; max?: number /* 99 */; tone?: "light" | "dark" /* "light" */; className?: string }`, renders nothing for `count <= 0`, `"99+"` past `max`, `aria-hidden` — the host names the count). Both exported from `@/components/frndos/v2`.

- [ ] **Step 1: `FloatingActionBar`**

Create `src/components/frndos/v2/FloatingActionBar.tsx`:

```tsx
"use client";

import clsx from "clsx";
import { forwardRef, type ReactNode } from "react";

export interface FloatingActionBarProps {
  /** Names the bar for screen readers ("Ready for client"). */
  ariaLabel: string;
  children: ReactNode;
  className?: string;
}

/**
 * FloatingActionBar (frndOS v2)
 *
 * A floating glass bar of "here is something, act on it" — thumbnails or a
 * label on the left, one primary action, a way to put it away. The
 * `DropSuggestionBar` / `FloatingSelectionBar` glass recipe, without either
 * one's positioning or focus behaviour: the CALLER positions it (a canvas
 * tray sits above its own bottom toolbar, not above the page nav), and it
 * never takes focus or binds keys — it appears on its own, often, and must
 * not interrupt typing.
 *
 * `frndos-float-panel` is theme-aware (Midnight, Aurora, Daylight); the
 * border and text are `white/N` + inverse tokens, which flip in Daylight.
 */
export const FloatingActionBar = forwardRef<
  HTMLDivElement,
  FloatingActionBarProps
>(function FloatingActionBar({ ariaLabel, children, className }, ref) {
  return (
    <div
      ref={ref}
      role="region"
      aria-label={ariaLabel}
      className={clsx(
        "frndos-float-panel flex w-fit max-w-full items-center gap-3 rounded-2xl border border-white/10 p-2 font-geist shadow-2xl backdrop-blur-xl transition-all duration-200 ease-out animate-in fade-in slide-in-from-bottom-2",
        className
      )}
    >
      {children}
    </div>
  );
});

export default FloatingActionBar;
```

- [ ] **Step 2: `CountBadge`**

Create `src/components/frndos/v2/CountBadge.tsx`:

```tsx
"use client";

import clsx from "clsx";

export interface CountBadgeProps {
  count: number;
  /** Past this it reads "{max}+". */
  max?: number;
  /**
   * `light` = a light pill (on dark glass, e.g. over an icon button);
   * `dark` = a dark pill (inside a white primary button). Both are `white/N`
   * / `black/N` + tokens, so they flip together with their host in Daylight.
   */
  tone?: "light" | "dark";
  className?: string;
}

/**
 * CountBadge (frndOS v2)
 *
 * A small count pill riding on a button or an icon ("Ready for client ⑥").
 * Decorative: `aria-hidden`, because the host's accessible name already
 * carries the number ("Ready for client — 6 artboards"). Nothing for zero.
 */
export function CountBadge({
  count,
  max = 99,
  tone = "light",
  className,
}: CountBadgeProps) {
  if (count <= 0) return null;
  return (
    <span
      aria-hidden
      className={clsx(
        "inline-flex h-4 min-w-4 shrink-0 items-center justify-center rounded-full px-1 font-geist text-textXsMedium tabular-nums",
        tone === "light"
          ? "bg-white text-text-default"
          : "bg-black/80 text-text-inverse",
        className
      )}
    >
      {count > max ? `${max}+` : count}
    </span>
  );
}

export default CountBadge;
```

- [ ] **Step 3: Export**

Append to `src/components/frndos/v2/index.ts`:

```ts
// A floating glass action bar the caller positions (the KV ready tray).
export { default as FloatingActionBar } from "./FloatingActionBar";
export type { FloatingActionBarProps } from "./FloatingActionBar";
// A small count pill on a button or an icon ("Ready for client ⑥").
export { default as CountBadge } from "./CountBadge";
export type { CountBadgeProps } from "./CountBadge";
```

- [ ] **Step 4: Stories**

Create `src/components/frndos/stories/FloatingActionBarV2.stories.tsx`:

```tsx
import type { Meta, StoryObj } from "@storybook/react";
import React from "react";
import { Minus } from "@phosphor-icons/react";
import { Button } from "../v2/Button";
import { FloatingActionBar } from "../v2/FloatingActionBar";

const meta: Meta<typeof FloatingActionBar> = {
  title: "FrndOS v2/FloatingActionBar",
  component: FloatingActionBar,
  tags: ["autodocs"],
  parameters: {
    backgrounds: { default: "dark" },
    docs: {
      description: {
        component:
          "**frndOS v2** — a floating glass action bar the caller positions (the KV canvas's Ready-for-client tray). Never takes focus, binds no keys.",
      },
    },
  },
};

export default meta;
type Story = StoryObj<typeof FloatingActionBar>;

export const ReadyTray: Story = {
  render: () => (
    <FloatingActionBar ariaLabel="Ready for client">
      <ul className="flex -space-x-2">
        {[0, 1, 2].map((i) => (
          <li
            key={i}
            className="size-8 rounded-md border border-white/10 bg-white/10"
          />
        ))}
      </ul>
      <span className="text-textSmMedium text-text-inverse">
        6 ready for client
      </span>
      <Button size="small">Request approval</Button>
      <Button variant="icon" size="tiny" aria-label="Hide">
        <Minus size={12} />
      </Button>
    </FloatingActionBar>
  ),
};
```

Create `src/components/frndos/stories/CountBadgeV2.stories.tsx`:

```tsx
import type { Meta, StoryObj } from "@storybook/react";
import React from "react";
import { PaperPlaneTilt } from "@phosphor-icons/react";
import { Button } from "../v2/Button";
import { CountBadge } from "../v2/CountBadge";

const meta: Meta<typeof CountBadge> = {
  title: "FrndOS v2/CountBadge",
  component: CountBadge,
  tags: ["autodocs"],
  parameters: {
    backgrounds: { default: "dark" },
    docs: {
      description: {
        component:
          "**frndOS v2** — a small count pill on a button or icon. `aria-hidden`: the host names the count. Nothing for 0; `99+` past `max`.",
      },
    },
  },
};

export default meta;
type Story = StoryObj<typeof CountBadge>;

export const InPrimaryButton: Story = {
  render: () => (
    <Button size="small" rightIcon={<CountBadge count={6} tone="dark" />}>
      Ready for client
    </Button>
  ),
};

export const OnIconButton: Story = {
  render: () => (
    <span className="relative inline-flex">
      <Button variant="icon" size="small" aria-label="Ready for client — 6">
        <PaperPlaneTilt size={16} />
      </Button>
      <CountBadge count={6} className="absolute -right-1.5 -top-1.5" />
    </span>
  ),
};

export const Capped: Story = { args: { count: 120 } };
```

(If `Button` is a default-only export in `../v2/Button`, import it as `import Button from "../v2/Button";` — check the existing `ButtonV2.stories.tsx` and copy its import line.)

- [ ] **Step 5: Skill rows**

In `.agents/skills/frndos-components-v2/SKILL.md`, add two rows to the "Daftar Komponen v2 Available" table, directly after the `DropSuggestionBar` row:

```markdown
| FloatingActionBar                   | `@/components/frndos/v2`        | native `<div role="region">`                    | Floating glass action bar the CALLER positions (KV canvas Ready-for-client tray): `ariaLabel`, `children` (thumbnails/label · one primary `Button` · a tuck `Button variant="icon"`), `className`; forwards its ref. The `frndos-float-panel` glass of `DropSuggestionBar`, without its focus-on-mount or global Escape — it appears often and must never interrupt typing. Use `FloatingSelectionBar` (v1) for page bulk bars inside the SidebarShell. |
| CountBadge                          | `@/components/frndos/v2`        | native `<span aria-hidden>`                     | Small count pill on a button or icon ("Ready for client ⑥"): `count` (nothing for ≤ 0), `max` (default 99 → "99+"), `tone` (`light` on glass/icon buttons, `dark` inside a white primary `Button` via `rightIcon`). Decorative — the host's `aria-label` carries the number. |
```

- [ ] **Step 6: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/frndos/v2/FloatingActionBar.tsx src/components/frndos/v2/CountBadge.tsx src/components/frndos/v2/index.ts src/components/frndos/stories/FloatingActionBarV2.stories.tsx src/components/frndos/stories/CountBadgeV2.stories.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "FloatingActionBar|CountBadge|frndos/v2/index"
```

Expected: clean; the tsc grep prints nothing.

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/frndos/v2/FloatingActionBar.tsx src/components/frndos/v2/CountBadge.tsx src/components/frndos/v2/index.ts src/components/frndos/stories/FloatingActionBarV2.stories.tsx src/components/frndos/stories/CountBadgeV2.stories.tsx .agents/skills/frndos-components-v2/SKILL.md && /usr/bin/git commit -F - <<'EOF'
feat(web): v2 FloatingActionBar and CountBadge

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 3: Query freshness and the request form's prefill

**Files:**
- Modify: `src/hooks/useKvReadyToShare.ts`
- Modify: `src/components/studio/kv-generator/KvSharePanel.tsx`
- Modify: `src/components/client-lane/agency/useApproverEmails.ts`
- Modify: `src/components/client-lane/agency/KvRequestForm.tsx`

**Interfaces:**
- Consumes: `approvalRequestsRoot` (`@/services/client-lane`), `requestDefaultMessage` (Task 1).
- Produces: `useApproverEmails(brandId?: string | null, initial?: readonly string[])`; `KvRequestForm` gains optional props `initialEmails?: string[]` and `prefillMessage?: boolean` (Task 6 passes both; the Share dialog passes neither, so its behaviour is unchanged).

- [ ] **Step 1: Mark / unmark refresh the request queries**

In `src/hooks/useKvReadyToShare.ts` add the import

```ts
import { approvalRequestsRoot } from "@/services/client-lane";
```

and replace the `invalidate` helper with:

```ts
  const invalidate = () => {
    if (!fileId) return;
    void qc.invalidateQueries({ queryKey });
    // Part B (spec 2026-10-01 §6.1): the tray, the top-bar slot and the
    // Share dialog read the request PREVIEW, which is "what is marked ready
    // and not yet approved" — a mark or unmark changes it.
    void qc.invalidateQueries({ queryKey: approvalRequestsRoot(fileId) });
  };
```

(`onError: invalidate, onSettled: invalidate` on both mutations stay as they are, so both now refresh both.)

- [ ] **Step 2: Closing the Share dialog refreshes them**

In `src/components/studio/kv-generator/KvSharePanel.tsx`: change the React import to `import { useEffect, useMemo, useState } from "react";`, add

```ts
import { useQueryClient } from "@tanstack/react-query";
import { approvalRequestsRoot } from "@/services/client-lane";
```

and, directly after `const clientLane = useClientLaneEnabled();`, add:

```ts
  // Part B (spec 2026-10-01 §6.1): the canvas chips, tray and top-bar slot
  // read the same request queries this dialog does — closing it re-reads
  // them so they agree with whatever happened inside.
  const qc = useQueryClient();
  useEffect(() => {
    if (!open || !clientLane) return;
    return () => {
      void qc.invalidateQueries({ queryKey: approvalRequestsRoot(fileId) });
    };
  }, [open, clientLane, qc, fileId]);
```

- [ ] **Step 3: Initial approver emails**

In `src/components/client-lane/agency/useApproverEmails.ts` change the signature and the `emails` state:

```ts
export function useApproverEmails(
  brandId?: string | null,
  /** Prefilled approvers (the top-bar form carries the last request's). */
  initial?: readonly string[]
) {
  const [emails, setEmails] = useState<string[]>(() =>
    Array.from(
      new Set(
        (initial ?? [])
          .map((e) => e.trim().toLowerCase())
          .filter((e) => APPROVER_EMAIL.test(e))
      )
    ).slice(0, MAX_APPROVERS)
  );
```

(`APPROVER_EMAIL` and `MAX_APPROVERS` are declared above the hook in the same file, so they are initialised before the lazy initialiser runs.)

- [ ] **Step 4: Form prefill**

In `src/components/client-lane/agency/KvRequestForm.tsx`:

1. Import `requestDefaultMessage` from `@/lib/client-lane/canvasApproval`.
2. Add to `KvRequestForm`'s props (and destructuring) and pass both through to `<RequestFields … />`:

```ts
  /** Prefilled approvers (top-bar form: the file's last request's). */
  initialEmails?: string[];
  /** Prefill the message with "{n} artboards ready: Craft 1 · Resize 5",
   *  following the phase pills until the user types (top-bar form). */
  prefillMessage?: boolean;
```

3. In `RequestFields` (add the same two props to its prop type):
   - `const approvers = useApproverEmails(brandId, initialEmails);`
   - replace `const [message, setMessage] = useState("");` with `const [message, setMessage] = useState<string | null>(null);`
   - directly after the `const waiting = …` line add:

```ts
  // Untouched, the prefill follows the phase pills; the first keystroke
  // makes it the user's own text and it stops moving.
  const messageValue =
    message ?? (prefillMessage ? requestDefaultMessage(items) : "");
```

   - in `submit`, pass `message: messageValue` to `buildRequestPayload`;
   - the counter renders `{messageValue.length}/{MAX_MESSAGE}`; the textarea gets `value={messageValue}` (its `onChange` stays `setMessage(e.target.value)`).

- [ ] **Step 5 (test): Regression — the Share dialog is unchanged**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: the same pass count as the Task 0 baseline.

- [ ] **Step 6: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/hooks/useKvReadyToShare.ts src/components/studio/kv-generator/KvSharePanel.tsx src/components/client-lane/agency/useApproverEmails.ts src/components/client-lane/agency/KvRequestForm.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "useKvReadyToShare|KvSharePanel|useApproverEmails|KvRequestForm"
```

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/hooks/useKvReadyToShare.ts src/components/studio/kv-generator/KvSharePanel.tsx src/components/client-lane/agency/useApproverEmails.ts src/components/client-lane/agency/KvRequestForm.tsx && /usr/bin/git commit -F - <<'EOF'
feat(web): marks and the share dialog refresh request queries; request form prefill

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 4: Lift the request verbs into `useRequestActions`

The status popover (Task 5) needs exactly the Share dialog row's Copy link / Resend / Withdraw, with the same toasts, analytics and `round_closed` handling. Lift it once instead of copying.

**Files:**
- Create: `src/components/client-lane/agency/useRequestActions.tsx`
- Modify: `src/components/client-lane/agency/KvApprovalRequestsSection.tsx`

**Interfaces:**
- Consumes: Part A's `useWithdrawApprovalRequest`, `useResendApprovalRequest`, `approvalApiError`, `approvalRequestsRoot`; the existing analytics helpers.
- Produces: `useRequestActions(request: AgencyRequest, fileId: string): { verbs: ActionMenuItem[]; confirmingWithdraw: boolean; cancelWithdraw: () => void; doWithdraw: () => void; withdrawPending: boolean }`; `WithdrawConfirm({ title, pending, onConfirm, onKeep, className? })`.

- [ ] **Step 1: Create the hook**

Create `src/components/client-lane/agency/useRequestActions.tsx`. Its body is `RequestRow`'s `copyLink`, `doResend`, `doWithdraw` and `verbs` from `KvApprovalRequestsSection.tsx`, moved verbatim:

```tsx
"use client";

import { Copy } from "@phosphor-icons/react";
import { useQueryClient } from "@tanstack/react-query";
import clsx from "clsx";
import { useState } from "react";

import { Button, type ActionMenuItem } from "@/components/frndos/v2";
import {
  failureReason,
  trackApprovalLinkShared,
  trackApprovalRequestResendFailed,
  trackApprovalRequestResent,
  trackApprovalRequestWithdrawFailed,
  trackApprovalRequestWithdrawn,
} from "@/lib/analytics/client-lane-events";
import {
  approvalApiError,
  approvalRequestsRoot,
  useResendApprovalRequest,
  useWithdrawApprovalRequest,
  type AgencyRequest,
} from "@/services/client-lane";
import { useToastStore } from "@/store/useToast";

/**
 * Copy link, Resend and Withdraw for one KV approval request — the Share
 * dialog's request row and the canvas status popover (spec 2026-10-01 §5.2,
 * §6.1) run the same verbs, toasts and analytics. Rendered under
 * `KvSharePanel`, so toasts are read through the selector only.
 */
export function useRequestActions(request: AgencyRequest, fileId: string) {
  const showToast = useToastStore((s) => s.showToast);
  const qc = useQueryClient();
  const withdraw = useWithdrawApprovalRequest(fileId);
  const resend = useResendApprovalRequest();
  const [confirmingWithdraw, setConfirmingWithdraw] = useState(false);
  const open = request.status === "pending";
  const linkLive = request.share_link_active;

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
        setConfirmingWithdraw(false);
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
        setConfirmingWithdraw(false);
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

  const verbs: ActionMenuItem[] = [
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
            onSelect: () => setConfirmingWithdraw(true),
          },
        ]
      : []),
  ];

  return {
    verbs,
    confirmingWithdraw,
    cancelWithdraw: () => setConfirmingWithdraw(false),
    doWithdraw,
    withdrawPending: withdraw.isPending,
  };
}

/** "Withdraw Request n?" — the inline confirm under a request row. */
export function WithdrawConfirm({
  title,
  pending,
  onConfirm,
  onKeep,
  className,
}: {
  title: string;
  pending: boolean;
  onConfirm: () => void;
  onKeep: () => void;
  className?: string;
}) {
  return (
    <div
      role="group"
      aria-label={`Withdraw ${title}?`}
      className={clsx(
        "flex flex-wrap items-center gap-2 rounded-xl border border-white/10 bg-white/5 p-3",
        className
      )}
    >
      <p className="w-full font-geist text-textXs text-text-inverse-subtle">
        Nobody can decide on its artboards after this. Their decisions so far
        stay on record.
      </p>
      <Button
        variant="alertSecondary"
        size="small"
        loading={pending}
        disabled={pending}
        onClick={onConfirm}
      >
        Withdraw request
      </Button>
      <Button variant="text" size="small" disabled={pending} onClick={onKeep}>
        Keep
      </Button>
    </div>
  );
}
```

- [ ] **Step 2: Use it in the section**

In `src/components/client-lane/agency/KvApprovalRequestsSection.tsx`, in `RequestRow`:
- delete `showToast`, `qc`, `withdraw`, `resend`, `confirmWithdraw` state, `copyLink`, `doResend`, `doWithdraw` and `verbs`, and replace them with `const actions = useRequestActions(request, fileId);` (keep `expanded`, `panelId`, `title`, `linkLive`);
- `<ActionMenu ariaLabel={…} items={actions.verbs} />`;
- replace the `{confirmWithdraw && ( <div role="group" …> … </div> )}` block with

```tsx
      {actions.confirmingWithdraw && (
        <WithdrawConfirm
          className="ml-12 mt-1"
          title={title}
          pending={actions.withdrawPending}
          onConfirm={actions.doWithdraw}
          onKeep={actions.cancelWithdraw}
        />
      )}
```

- add `import { useRequestActions, WithdrawConfirm } from "./useRequestActions";` and remove the imports that became unused (`useQueryClient`, `approvalRequestsRoot`, `useResendApprovalRequest`, `useWithdrawApprovalRequest`, `approvalApiError`, the withdraw/resend/link-shared analytics helpers, `Copy` if nothing else uses it). `RequestDetail` keeps its own toast + personal-link copy unchanged.

- [ ] **Step 3 (test): Regression**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: the Task 0 pass count.

- [ ] **Step 4: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/client-lane/agency/useRequestActions.tsx src/components/client-lane/agency/KvApprovalRequestsSection.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "useRequestActions|KvApprovalRequestsSection"
```

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/client-lane/agency/useRequestActions.tsx src/components/client-lane/agency/KvApprovalRequestsSection.tsx && /usr/bin/git commit -F - <<'EOF'
refactor(web): request Copy link / Resend / Withdraw in one hook

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 5: `KvApprovalStatusList` — the status popover's body

**Files:**
- Create: `src/components/client-lane/agency/KvApprovalStatusList.tsx`
- Create: `src/components/client-lane/agency/KvApprovalStatusList.test.tsx`

**Interfaces:**
- Consumes: `useRequestActions`, `WithdrawConfirm` (Task 4); `artboardWho` (Task 1); `trackStatusRowJumped`, `ApprovalSurface` (Task 1); `StatusPill` (Part A wrapper); v2 `ItemRow`, `ActionMenu`.
- Produces: `KvApprovalStatusList({ requests: AgencyRequest[]; fileId: string; surface: ApprovalSurface; onJump: (approval: AgencyRequestApproval) => void })`.

- [ ] **Step 1 (test): Write the failing test**

Create `src/components/client-lane/agency/KvApprovalStatusList.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  agencyRequest,
  requestApproval,
} from "@/lib/client-lane/requestFixtures";

import { KvApprovalStatusList } from "./KvApprovalStatusList";

const body = () => within(document.body);

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

const tile = requestApproval({
  id: "apT",
  subject_key: "resize:r1",
  phase: "resize",
  label: "Resize · IG Story · 1080×1920",
  version_id: "r1",
  pin_count: 2,
});

const openRequest = agencyRequest({
  id: "q2",
  number: 2,
  approvals: [tile],
  approvers: [
    {
      name: "Dina",
      email: "dina@brand.test",
      user_id: "u1",
      personal_url: null,
      decided: false,
    },
  ],
});

const closedRequest = agencyRequest({
  id: "q1",
  number: 1,
  status: "approved",
  approvals: [requestApproval({ status: "approved" })],
  counts: {
    approved: 1,
    approved_with_changes: 0,
    changes_required: 0,
    pending: 0,
    superseded: 0,
  },
});

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("KvApprovalStatusList", () => {
  it("jumps to the artboard a row names", () => {
    const capture = vi.spyOn(posthog, "capture");
    const onJump = vi.fn();
    render(
      <KvApprovalStatusList
        requests={[openRequest, closedRequest]}
        fileId="f1"
        surface="canvas"
        onJump={onJump}
      />,
      { wrapper: Wrapper }
    );
    fireEvent.click(
      body().getByRole("button", {
        name: "Show Resize · IG Story · 1080×1920 on the canvas",
      })
    );
    expect(onJump).toHaveBeenCalledWith(tile);
    expect(capture).toHaveBeenCalledWith(
      "client_lane.status_row_jumped",
      expect.objectContaining({
        surface: "canvas",
        phase: "resize",
        status: "pending",
        replaced: false,
      })
    );
    expect(body().getByText("2 pins")).toBeInTheDocument();
  });

  it("offers Copy link, Resend and Withdraw on the open request only", () => {
    render(
      <KvApprovalStatusList
        requests={[openRequest, closedRequest]}
        fileId="f1"
        surface="canvas"
        onJump={vi.fn()}
      />,
      { wrapper: Wrapper }
    );
    const menus = body().getAllByRole("button", { name: /^Actions for / });
    expect(menus).toHaveLength(1);
    expect(menus[0]).toHaveAccessibleName("Actions for Request 2 · 1 artboard");
  });
});
```

- [ ] **Step 2 (test): Run — fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvApprovalStatusList.test.tsx
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

Create `src/components/client-lane/agency/KvApprovalStatusList.tsx`:

```tsx
"use client";

import { SealCheck } from "@phosphor-icons/react";
import clsx from "clsx";

import { ActionMenu, ItemRow } from "@/components/frndos/v2";
import {
  trackStatusRowJumped,
  type ApprovalSurface,
} from "@/lib/analytics/client-lane-events";
import { artboardWho } from "@/lib/client-lane/canvasApproval";
import {
  plural,
  requestRowDescription,
  requestTitle,
} from "@/lib/client-lane/requests";
import type {
  AgencyRequest,
  AgencyRequestApproval,
} from "@/services/client-lane";

import { StatusPill } from "../StatusPill";
import { useRequestActions, WithdrawConfirm } from "./useRequestActions";

const QUIET = "font-geist text-textXs text-text-inverse-subtlest";

/**
 * The body of the top-bar status popover (spec 2026-10-01 §6.1): every
 * request on the file — open first, as the api orders them — with one row
 * per artboard (verdict, who, when, pins). Copy link, Resend and Withdraw
 * only on the open request. A row takes the canvas to its artboard.
 */
export function KvApprovalStatusList({
  requests,
  fileId,
  surface,
  onJump,
}: {
  requests: AgencyRequest[];
  fileId: string;
  surface: ApprovalSurface;
  onJump: (approval: AgencyRequestApproval) => void;
}) {
  if (requests.length === 0) {
    return <p className={clsx("px-2 py-1.5", QUIET)}>No requests yet.</p>;
  }
  return (
    <ul aria-label="Approval requests" className="flex flex-col gap-3">
      {requests.map((request) => (
        <li key={request.id}>
          <StatusRequest
            request={request}
            fileId={fileId}
            surface={surface}
            onJump={onJump}
          />
        </li>
      ))}
    </ul>
  );
}

function StatusRequest({
  request,
  fileId,
  surface,
  onJump,
}: {
  request: AgencyRequest;
  fileId: string;
  surface: ApprovalSurface;
  onJump: (approval: AgencyRequestApproval) => void;
}) {
  const actions = useRequestActions(request, fileId);
  const open = request.status === "pending";
  const title = requestTitle(request);
  const description = request.share_link_active
    ? requestRowDescription(request)
    : `${requestRowDescription(request)} · Link no longer active`;

  return (
    <div className="flex flex-col gap-1">
      <ItemRow
        icon={
          <ItemRow.Glyph>
            <SealCheck size={16} />
          </ItemRow.Glyph>
        }
        title={title}
        badge={<StatusPill status={request.status} />}
        description={description}
        trailing={
          open ? (
            <ActionMenu
              ariaLabel={`Actions for ${title}`}
              items={actions.verbs}
            />
          ) : undefined
        }
      />
      {actions.confirmingWithdraw && (
        <WithdrawConfirm
          title={title}
          pending={actions.withdrawPending}
          onConfirm={actions.doWithdraw}
          onKeep={actions.cancelWithdraw}
        />
      )}
      <ul
        aria-label={`Artboards in Request ${request.number}`}
        className="flex flex-col gap-0.5 pl-10"
      >
        {request.approvals.map((approval) => (
          <li key={approval.id}>
            <ArtboardJumpRow
              approval={approval}
              onJump={() => {
                trackStatusRowJumped({
                  surface,
                  phase: approval.phase,
                  status: approval.status,
                  replaced: approval.superseded_by_request_number !== null,
                });
                onJump(approval);
              }}
            />
          </li>
        ))}
      </ul>
    </div>
  );
}

function ArtboardJumpRow({
  approval,
  onJump,
}: {
  approval: AgencyRequestApproval;
  onJump: () => void;
}) {
  const meta = [
    artboardWho(approval),
    approval.pin_count > 0 ? plural(approval.pin_count, "pin") : null,
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <button
      type="button"
      onClick={onJump}
      aria-label={`Show ${approval.label} on the canvas`}
      className="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left font-geist outline-none transition-all duration-200 ease-out hover:bg-white/5 focus-visible:ring-2 focus-visible:ring-white/40"
    >
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
    </button>
  );
}
```

- [ ] **Step 4 (test): Run — passes**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvApprovalStatusList.test.tsx
```

- [ ] **Step 5 (test): Mutation checks**

1. Change `trailing={open ? (…) : undefined}` to always render the `ActionMenu` → "offers … on the open request only" fails.
2. Change `onJump(approval)` to `onJump(request.approvals[0])` and give the test's open request a second approval first in the list (temporarily) — or simpler: delete `onJump(approval);` → "jumps to the artboard a row names" fails.

- [ ] **Step 6: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/client-lane/agency/KvApprovalStatusList.tsx src/components/client-lane/agency/KvApprovalStatusList.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "KvApprovalStatusList"
```

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/client-lane/agency/KvApprovalStatusList.tsx src/components/client-lane/agency/KvApprovalStatusList.test.tsx && /usr/bin/git commit -F - <<'EOF'
feat(web): approval status list — every request, verbs on the open one, artboard rows that jump

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 6: `KvClientApprovalSlot` — the top-bar slot

**Files:**
- Create: `src/components/client-lane/agency/KvClientApprovalSlot.tsx`
- Create: `src/components/client-lane/agency/KvClientApprovalSlot.test.tsx`

**Interfaces:**
- Consumes: `useApprovalRequestPreview`, `useApprovalRequests` (Part A); `slotStateOf`, `lastRequestEmails` (Task 1); `TONE_DOT` (Task 1); `CountBadge` (Task 2); `KvRequestForm` with `initialEmails` / `prefillMessage` (Task 3); `KvApprovalStatusList` (Task 5); `trackApprovalRequestFormOpened`, `trackStatusChipOpened`, `ApprovalSurface`.
- Produces:

```ts
export interface KvClientApprovalSlotProps {
  fileId: string;
  fileName: string;
  brandId: string | null;
  /** Narrow top bar: icon + badge, and the chip shows the fraction only. */
  compact?: boolean;
  surface: ApprovalSurface;
  /** The request form drop-down — host state, so the tray can open it. */
  formOpen: boolean;
  onFormOpenChange: (open: boolean) => void;
  /** Hover / focus on a "ready" affordance: the set to frame; null to clear. */
  onHoverReadySet?: (items: ApprovalRequestPreviewItem[] | null) => void;
  onJump: (approval: AgencyRequestApproval) => void;
}
export function KvClientApprovalSlot(props: KvClientApprovalSlotProps): JSX.Element;
export function keepFormOpenOnPress(target: EventTarget | null, slot: Element | null): boolean;
```

- [ ] **Step 1 (test): Write the failing tests**

Create `src/components/client-lane/agency/KvClientApprovalSlot.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  agencyRequest,
  previewItem,
  requestApproval,
  requestPreview,
} from "@/lib/client-lane/requestFixtures";
import axiosInstance from "@/services/axios";
import type {
  AgencyRequest,
  ApprovalRequestPreview,
} from "@/services/client-lane";

import {
  KvClientApprovalSlot,
  keepFormOpenOnPress,
} from "./KvClientApprovalSlot";

const body = () => within(document.body);

function Wrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function stub(preview: ApprovalRequestPreview, requests: AgencyRequest[]) {
  vi.spyOn(axiosInstance, "get").mockImplementation((async (url: string) => {
    if (url === "v1/approval-requests/preview")
      return { data: { data: preview } };
    if (url === "v1/approval-requests") return { data: { data: requests } };
    throw new Error(`unexpected GET ${url}`);
  }) as never);
}

const ready = (n: number) =>
  requestPreview(
    Array.from({ length: n }, (_, i) =>
      previewItem({ subject_key: `resize:r${i}`, phase: "resize" })
    )
  );

const sixPending = agencyRequest({
  approvers: [
    {
      name: "Dina",
      email: "dina@brand.test",
      user_id: "u1",
      personal_url: null,
      decided: false,
    },
  ],
  approvals: Array.from({ length: 6 }, (_, i) =>
    requestApproval({ id: `a${i}`, subject_key: `board:g${i}` })
  ),
  counts: {
    approved: 0,
    approved_with_changes: 0,
    changes_required: 0,
    pending: 6,
    superseded: 0,
  },
});

function renderSlot(
  overrides: Partial<Parameters<typeof KvClientApprovalSlot>[0]> = {}
) {
  const props = {
    fileId: "f1",
    fileName: "Ramadan hero",
    brandId: null,
    surface: "canvas" as const,
    formOpen: false,
    onFormOpenChange: vi.fn(),
    onJump: vi.fn(),
    ...overrides,
  };
  render(<KvClientApprovalSlot {...props} />, { wrapper: Wrapper });
  return props;
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("KvClientApprovalSlot", () => {
  it("offers Ready for client with the count when nothing was sent yet", async () => {
    stub(ready(6), []);
    renderSlot();
    const button = await body().findByRole("button", {
      name: "Ready for client — 6 artboards",
    });
    expect(button).toHaveTextContent("Ready for client");
    expect(button).toHaveTextContent("6");
  });

  it("is an icon with the count in a compact bar", async () => {
    stub(ready(6), []);
    renderSlot({ compact: true });
    await body().findByRole("button", {
      name: "Ready for client — 6 artboards",
    });
    expect(body().queryByText("Ready for client")).toBeNull();
    expect(body().getByText("6")).toBeInTheDocument();
  });

  it("opens the form from the top bar and says so", async () => {
    const capture = vi.spyOn(posthog, "capture");
    stub(ready(6), []);
    const props = renderSlot();
    fireEvent.click(
      await body().findByRole("button", {
        name: "Ready for client — 6 artboards",
      })
    );
    expect(props.onFormOpenChange).toHaveBeenCalledWith(true);
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_form_opened",
      expect.objectContaining({ source: "top_bar", ready_total: 6 })
    );
  });

  it("shows the open request as a chip and new ready artboards as +n", async () => {
    stub(ready(2), [sixPending]);
    renderSlot();
    expect(
      await body().findByRole("button", {
        name: "Approval status: Waiting on Dina · 0/6",
      })
    ).toHaveTextContent("Waiting on Dina · 0/6");
    expect(
      body().getByRole("button", {
        name: "Request approval — 2 new artboards ready",
      })
    ).toHaveTextContent("+2 ready");
    expect(
      body().queryByRole("button", { name: /^Ready for client/ })
    ).toBeNull();
  });

  it("shows only the fraction on the chip in a compact bar", async () => {
    stub(ready(0), [sixPending]);
    renderSlot({ compact: true });
    expect(
      await body().findByRole("button", {
        name: "Approval status: Waiting on Dina · 0/6",
      })
    ).toHaveTextContent(/^0\/6$/);
  });

  it("lists the requests when the chip is clicked", async () => {
    const capture = vi.spyOn(posthog, "capture");
    stub(ready(0), [sixPending]);
    renderSlot();
    await userEvent.click(
      await body().findByRole("button", {
        name: "Approval status: Waiting on Dina · 0/6",
      })
    );
    expect(
      await body().findByRole("list", { name: "Artboards in Request 1" })
    ).toBeInTheDocument();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.status_chip_opened",
      expect.objectContaining({
        surface: "canvas",
        request_status: "pending",
        request_count: 1,
      })
    );
  });
});

describe("keepFormOpenOnPress", () => {
  it("keeps the form open for a press inside the Decide-by calendar", () => {
    const wrapper = document.createElement("div");
    wrapper.setAttribute("data-radix-popper-content-wrapper", "");
    const day = document.createElement("button");
    wrapper.appendChild(day);
    document.body.appendChild(wrapper);
    try {
      expect(keepFormOpenOnPress(day, null)).toBe(true);
    } finally {
      wrapper.remove();
    }
  });

  it("keeps it open for a press on the slot itself, closes it elsewhere", () => {
    const slot = document.createElement("div");
    const inside = document.createElement("button");
    slot.appendChild(inside);
    const outside = document.createElement("div");
    document.body.append(slot, outside);
    try {
      expect(keepFormOpenOnPress(inside, slot)).toBe(true);
      expect(keepFormOpenOnPress(outside, slot)).toBe(false);
      expect(keepFormOpenOnPress(null, slot)).toBe(false);
    } finally {
      slot.remove();
      outside.remove();
    }
  });
});
```

- [ ] **Step 2 (test): Run — fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvClientApprovalSlot.test.tsx
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

Create `src/components/client-lane/agency/KvClientApprovalSlot.tsx`:

```tsx
"use client";

import { PaperPlaneTilt } from "@phosphor-icons/react";
import clsx from "clsx";
import { useRef, useState } from "react";

import { Button, CountBadge, Popover, Tooltip } from "@/components/frndos/v2";
import {
  trackApprovalRequestFormOpened,
  trackStatusChipOpened,
  type ApprovalSurface,
} from "@/lib/analytics/client-lane-events";
import {
  lastRequestEmails,
  slotStateOf,
  type SlotState,
} from "@/lib/client-lane/canvasApproval";
import { plural } from "@/lib/client-lane/requests";
import { TONE_DOT } from "@/lib/client-lane/statusTone";
import {
  useApprovalRequestPreview,
  useApprovalRequests,
  type AgencyRequestApproval,
  type ApprovalRequestPreviewItem,
} from "@/services/client-lane";

import { KvApprovalStatusList } from "./KvApprovalStatusList";
import { KvRequestForm } from "./KvRequestForm";

/**
 * Whether a press that Base UI calls "outside" must NOT close the request
 * form. Two cases: the slot's own ready button (it is the form's anchor, not
 * its trigger), and the Decide-by calendar — a Radix popover portalled to
 * `<body>`, so to Base UI every date click is outside and would drop the
 * draft.
 */
export function keepFormOpenOnPress(
  target: EventTarget | null,
  slot: Element | null
): boolean {
  if (!(target instanceof Element)) return false;
  if (slot?.contains(target)) return true;
  return target.closest("[data-radix-popper-content-wrapper]") !== null;
}

export interface KvClientApprovalSlotProps {
  fileId: string;
  fileName: string;
  brandId: string | null;
  /** Narrow top bar: icon + badge, and the chip shows the fraction only. */
  compact?: boolean;
  surface: ApprovalSurface;
  /** The request form drop-down — host state, so the tray can open it. */
  formOpen: boolean;
  onFormOpenChange: (open: boolean) => void;
  /** Hover / focus on a "ready" affordance: the set to frame; null clears. */
  onHoverReadySet?: (items: ApprovalRequestPreviewItem[] | null) => void;
  onJump: (approval: AgencyRequestApproval) => void;
}

/**
 * The top-bar slot (spec 2026-10-01 §6.1), left of the avatars. Before any
 * request: **Ready for client ⑥** (an icon + badge when compact). After: a
 * status chip — the open request wins ("Waiting on Dina · 0/6"), else the
 * last result — with `+n ready` when something new is marked. The request
 * form drops down under the slot (the same `KvRequestForm` as the Share
 * dialog, prefilled); the chip opens every request with its artboards.
 */
export function KvClientApprovalSlot({
  fileId,
  fileName,
  brandId,
  compact = false,
  surface,
  formOpen,
  onFormOpenChange,
  onHoverReadySet,
  onJump,
}: KvClientApprovalSlotProps) {
  const slotRef = useRef<HTMLDivElement | null>(null);
  const [statusOpen, setStatusOpen] = useState(false);
  const preview = useApprovalRequestPreview(fileId);
  const requests = useApprovalRequests(fileId);
  const list = requests.data ?? [];
  const readyItems = preview.data?.items ?? [];
  const readyTotal = preview.data?.total ?? 0;
  const state: SlotState = requests.isSuccess
    ? slotStateOf(list, readyTotal)
    : { kind: "hidden" };

  const openForm = () => {
    trackApprovalRequestFormOpened({
      source: "top_bar",
      ready_total: readyTotal,
    });
    onHoverReadySet?.(null);
    onFormOpenChange(true);
  };
  const hover = {
    onMouseEnter: () => onHoverReadySet?.(readyItems),
    onMouseLeave: () => onHoverReadySet?.(null),
    onFocus: () => onHoverReadySet?.(readyItems),
    onBlur: () => onHoverReadySet?.(null),
  };
  const readyLabel = `Ready for client — ${plural(readyTotal, "artboard")}`;

  return (
    <div ref={slotRef} className="flex items-center gap-2">
      {state.kind === "ready" &&
        (compact ? (
          <Tooltip content={readyLabel}>
            <span className="relative inline-flex">
              <Button
                variant="icon"
                size="small"
                aria-label={readyLabel}
                onClick={openForm}
                {...hover}
              >
                <PaperPlaneTilt size={16} />
              </Button>
              <CountBadge
                count={state.readyTotal}
                className="pointer-events-none absolute -right-1.5 -top-1.5"
              />
            </span>
          </Tooltip>
        ) : (
          <Button
            size="small"
            aria-label={readyLabel}
            rightIcon={<CountBadge count={state.readyTotal} tone="dark" />}
            onClick={openForm}
            {...hover}
          >
            Ready for client
          </Button>
        ))}

      {state.kind === "status" && (
        <>
          <Popover
            open={statusOpen}
            onOpenChange={(next) => {
              if (next) {
                trackStatusChipOpened({
                  surface,
                  request_status: state.request.status,
                  request_count: list.length,
                  ready_total: state.readyTotal,
                });
              }
              setStatusOpen(next);
            }}
          >
            <Popover.Trigger asChild>
              <Button
                variant="secondary"
                size="small"
                aria-label={`Approval status: ${state.text}`}
                leftIcon={
                  <span
                    aria-hidden
                    className={clsx(
                      "size-2 rounded-full",
                      TONE_DOT[state.variant]
                    )}
                  />
                }
              >
                {compact ? state.shortText : state.text}
              </Button>
            </Popover.Trigger>
            <Popover.Content side="bottom" align="end" className="w-96 p-2">
              <KvApprovalStatusList
                requests={list}
                fileId={fileId}
                surface={surface}
                onJump={(approval) => {
                  setStatusOpen(false);
                  onJump(approval);
                }}
              />
            </Popover.Content>
          </Popover>
          {state.readyTotal > 0 && (
            <Button
              variant="text"
              size="tiny"
              aria-label={`Request approval — ${plural(state.readyTotal, "new artboard")} ready`}
              onClick={openForm}
              {...hover}
            >
              +{state.readyTotal} ready
            </Button>
          )}
        </>
      )}

      {/* The form drop-down: anchored to the slot, not to one trigger, so
          the tray can open it too (spec §6.1 "drops down under the slot"). */}
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
          <KvRequestForm
            fileId={fileId}
            fileName={fileName}
            brandId={brandId}
            initialEmails={lastRequestEmails(list)}
            prefillMessage
            onDone={() => onFormOpenChange(false)}
            onCancel={() => onFormOpenChange(false)}
          />
        </Popover.Content>
      </Popover>
    </div>
  );
}
```

- [ ] **Step 4 (test): Run — passes**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvClientApprovalSlot.test.tsx
```

If "lists the requests when the chip is clicked" cannot find the list, the Popover portal needs the user-event pointer sequence: keep `userEvent.click` (not `fireEvent`), as `KvCreativityButton.test.tsx` does for its Base UI menu.

- [ ] **Step 5 (test): Mutation checks**

1. In `keepFormOpenOnPress`, delete the `closest("[data-radix-popper-content-wrapper]")` line (return `false`) → "keeps the form open for a press inside the Decide-by calendar" fails.
2. Render `{state.text}` in compact too → "shows only the fraction on the chip in a compact bar" fails.
3. Delete `trackApprovalRequestFormOpened(…)` in `openForm` → "opens the form from the top bar and says so" fails.

- [ ] **Step 6: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/client-lane/agency/KvClientApprovalSlot.tsx src/components/client-lane/agency/KvClientApprovalSlot.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "KvClientApprovalSlot"
```

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/client-lane/agency/KvClientApprovalSlot.tsx src/components/client-lane/agency/KvClientApprovalSlot.test.tsx && /usr/bin/git commit -F - <<'EOF'
feat(web): top-bar client slot — Ready for client, status chip + popover, form drop-down

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 7: `KvReadyForClientTray`

**Files:**
- Create: `src/lib/client-lane/readyTray.ts`
- Create: `src/components/client-lane/agency/KvReadyForClientTray.tsx`
- Create: `src/components/client-lane/agency/KvReadyForClientTray.test.tsx`

**Interfaces:**
- Consumes: `useApprovalRequestPreview`; `FloatingActionBar`, `Button` (v2); `trackReadyTrayShown`, `trackReadyTrayTucked`, `trackApprovalRequestFormOpened`; `BOTTOM_TOOLBAR_SAFE_PX` (`@/lib/studio/kv/canvasSafeZones`).
- Produces: `KvReadyForClientTray({ fileId: string; suppressed?: boolean; onRequest: () => void })`. Tucks on a `pointerdown` inside any element marked `[data-kv-canvas-surface]` (Task 11 adds that attribute to the canvas wrapper). `readyTray.ts`: `readySetKeys(items)`, `isTuckedFor(current, tucked)`, `readTucked(fileId)`, `writeTucked(fileId, keys)`, `markTrayShown(fileId, keys): boolean`.

Rulings: the tray is **tucked while the current set is a subset of the tucked set** — unmarking never brings it back, a new key or a new version of a tucked key does. The tray hides while the request form is open (`suppressed`): the user is already acting on it.

- [ ] **Step 1: Storage helpers**

Create `src/lib/client-lane/readyTray.ts`:

```ts
/**
 * The ready tray's memory (spec 2026-10-01 §6.1): tucked per file in
 * `sessionStorage`, keyed by the set it was tucked on. Best-effort — blocked
 * storage just means the tray shows again.
 */
import type { ApprovalRequestPreviewItem } from "@/services/client-lane";

const tuckedKey = (fileId: string) => `frnd_kv_ready_tray_tucked:${fileId}`;
const shownKey = (fileId: string) => `frnd_kv_ready_tray_shown:${fileId}`;

/** One key per ready artboard VERSION, sorted: a regenerated artboard is a
 *  new key, so it counts as "something new". */
export function readySetKeys(
  items: Pick<ApprovalRequestPreviewItem, "subject_key" | "version_id">[]
): string[] {
  return items.map((i) => `${i.subject_key}@${i.version_id}`).sort();
}

/** Tucked while nothing in the current set is new to the tucked one —
 *  unmarking (a smaller set) stays tucked. */
export function isTuckedFor(
  current: string[],
  tucked: string[] | null
): boolean {
  if (!tucked) return false;
  const set = new Set(tucked);
  return current.every((k) => set.has(k));
}

function readKeys(key: string): string[] | null {
  try {
    const raw = window.sessionStorage.getItem(key);
    if (!raw) return null;
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) && parsed.every((k) => typeof k === "string")
      ? parsed
      : null;
  } catch {
    return null;
  }
}

function writeKeys(key: string, keys: string[]): void {
  try {
    window.sessionStorage.setItem(key, JSON.stringify(keys));
  } catch {
    // Storage blocked — the tray shows again next time.
  }
}

export const readTucked = (fileId: string) => readKeys(tuckedKey(fileId));

export const writeTucked = (fileId: string, keys: string[]) =>
  writeKeys(tuckedKey(fileId), keys);

/** True the first time this set is shown this session (the impression). */
export function markTrayShown(fileId: string, keys: string[]): boolean {
  const last = readKeys(shownKey(fileId));
  if (last && last.join("|") === keys.join("|")) return false;
  writeKeys(shownKey(fileId), keys);
  return true;
}
```

- [ ] **Step 2 (test): Write the failing tests**

Create `src/components/client-lane/agency/KvReadyForClientTray.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import posthog from "posthog-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { previewItem, requestPreview } from "@/lib/client-lane/requestFixtures";
import axiosInstance from "@/services/axios";
import {
  approvalRequestPreviewKey,
  type ApprovalRequestPreview,
} from "@/services/client-lane";

import { KvReadyForClientTray } from "./KvReadyForClientTray";

const body = () => within(document.body);
const tray = () => body().queryByRole("region", { name: "Ready for client" });

let current: ApprovalRequestPreview;

function stubPreview() {
  vi.spyOn(axiosInstance, "get").mockImplementation((async (url: string) => {
    if (url === "v1/approval-requests/preview")
      return { data: { data: current } };
    throw new Error(`unexpected GET ${url}`);
  }) as never);
}

function renderTray(onRequest = vi.fn()) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  render(
    <QueryClientProvider client={client}>
      <div data-kv-canvas-surface data-testid="canvas" />
      <KvReadyForClientTray fileId="f1" onRequest={onRequest} />
    </QueryClientProvider>
  );
  /** Swap what the api says is ready and let the tray re-read it. */
  const markedNow = async (next: ApprovalRequestPreview) => {
    current = next;
    await client.invalidateQueries();
    await waitFor(() =>
      expect(client.getQueryData(approvalRequestPreviewKey("f1"))).toEqual(
        next
      )
    );
  };
  return { onRequest, markedNow };
}

const A = previewItem({ subject_key: "board:g0", version_id: "g1" });
const B = previewItem({
  subject_key: "resize:r1",
  phase: "resize",
  version_id: "r1",
  label: "Resize · IG Story · 1080×1920",
});

beforeEach(() => {
  vi.restoreAllMocks();
  window.sessionStorage.clear();
});

describe("KvReadyForClientTray", () => {
  it("shows what is ready and opens the request form", async () => {
    const capture = vi.spyOn(posthog, "capture");
    current = requestPreview([A, B]);
    stubPreview();
    const { onRequest } = renderTray();
    expect(await body().findByText("2 ready for client")).toBeInTheDocument();
    fireEvent.click(body().getByRole("button", { name: "Request approval" }));
    expect(onRequest).toHaveBeenCalledTimes(1);
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approval_request_form_opened",
      expect.objectContaining({ source: "tray", ready_total: 2 })
    );
    expect(
      capture.mock.calls.filter(([e]) => e === "client_lane.ready_tray_shown")
    ).toHaveLength(1);
  });

  it("stays tucked when a ready artboard is unmarked", async () => {
    current = requestPreview([A, B]);
    stubPreview();
    const { markedNow } = renderTray();
    fireEvent.click(
      await body().findByRole("button", {
        name: "Hide until something new is ready",
      })
    );
    expect(tray()).toBeNull();
    await markedNow(requestPreview([A]));
    expect(tray()).toBeNull();
  });

  it("tucks on a canvas press and comes back for a new mark", async () => {
    current = requestPreview([A]);
    stubPreview();
    const { markedNow } = renderTray();
    await body().findByRole("region", { name: "Ready for client" });
    fireEvent.pointerDown(body().getByTestId("canvas"));
    expect(tray()).toBeNull();
    await markedNow(requestPreview([A, B]));
    expect(await body().findByText("2 ready for client")).toBeInTheDocument();
  });

  it("comes back for a new version of a tucked artboard", async () => {
    current = requestPreview([A]);
    stubPreview();
    const { markedNow } = renderTray();
    fireEvent.click(
      await body().findByRole("button", {
        name: "Hide until something new is ready",
      })
    );
    await markedNow(requestPreview([{ ...A, version_id: "g2" }]));
    expect(await body().findByText("1 ready for client")).toBeInTheDocument();
  });
});
```

- [ ] **Step 3 (test): Run — fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvReadyForClientTray.test.tsx
```

Expected: FAIL — module not found.

- [ ] **Step 4: Implement**

Create `src/components/client-lane/agency/KvReadyForClientTray.tsx`:

```tsx
"use client";

import { FilmStrip, Minus } from "@phosphor-icons/react";
import { useEffect, useMemo, useRef, useState } from "react";

import { Button, FloatingActionBar } from "@/components/frndos/v2";
import {
  trackApprovalRequestFormOpened,
  trackReadyTrayShown,
  trackReadyTrayTucked,
} from "@/lib/analytics/client-lane-events";
import {
  isTuckedFor,
  markTrayShown,
  readTucked,
  readySetKeys,
  writeTucked,
} from "@/lib/client-lane/readyTray";
import { BOTTOM_TOOLBAR_SAFE_PX } from "@/lib/studio/kv/canvasSafeZones";
import { useApprovalRequestPreview } from "@/services/client-lane";

const MAX_THUMBS = 5;

/**
 * "Ready for client" (spec 2026-10-01 §6.1): a floating bar above the
 * canvas's bottom nav, centred, while something is marked ready that no
 * request holds yet. Up to five thumbnails + `+n`, the count, **Request
 * approval** (opens the top-bar form) and `–`. `–` or the next press on the
 * canvas tucks it — no timer — until something NEW is marked (per file, this
 * session).
 */
export function KvReadyForClientTray({
  fileId,
  suppressed = false,
  onRequest,
}: {
  fileId: string;
  /** Hidden while the request form is open — the user is already on it. */
  suppressed?: boolean;
  onRequest: () => void;
}) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const preview = useApprovalRequestPreview(fileId);
  const items = useMemo(() => preview.data?.items ?? [], [preview.data]);
  const keys = useMemo(() => readySetKeys(items), [items]);
  const signature = keys.join("|");
  const [tucked, setTucked] = useState<string[] | null>(() =>
    readTucked(fileId)
  );
  const visible =
    !suppressed && items.length > 0 && !isTuckedFor(keys, tucked);

  useEffect(() => {
    if (!visible) return;
    if (markTrayShown(fileId, keys)) {
      trackReadyTrayShown({ ready_total: items.length });
    }
    // `signature` stands for `keys` (a fresh array every render).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visible, fileId, signature]);

  const tuck = (method: "button" | "canvas") => {
    writeTucked(fileId, keys);
    setTucked(keys);
    trackReadyTrayTucked({ ready_total: items.length, method });
  };
  const tuckRef = useRef(tuck);
  tuckRef.current = tuck;

  // "The next canvas pointer-down outside the tray" tucks it.
  useEffect(() => {
    if (!visible) return;
    const onDown = (e: Event) => {
      const target = e.target;
      if (!(target instanceof Element)) return;
      if (rootRef.current?.contains(target)) return;
      if (!target.closest("[data-kv-canvas-surface]")) return;
      tuckRef.current("canvas");
    };
    document.addEventListener("pointerdown", onDown, true);
    return () => document.removeEventListener("pointerdown", onDown, true);
  }, [visible]);

  if (!visible) return null;
  const thumbs = items.slice(0, MAX_THUMBS);
  const more = items.length - thumbs.length;

  return (
    <div
      ref={rootRef}
      className="pointer-events-none absolute inset-x-0 z-30 flex justify-center px-4"
      style={{ bottom: BOTTOM_TOOLBAR_SAFE_PX + 8 }}
    >
      <FloatingActionBar ariaLabel="Ready for client" className="pointer-events-auto">
        <ul aria-label="Ready artboards" className="flex items-center -space-x-2">
          {thumbs.map((item) => (
            <li key={`${item.subject_key}@${item.version_id}`}>
              {item.thumbnail_url ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  src={item.thumbnail_url}
                  alt={item.label}
                  className="size-8 rounded-md border border-white/10 object-cover"
                />
              ) : (
                <span
                  role="img"
                  aria-label={item.label}
                  className="flex size-8 items-center justify-center rounded-md border border-white/10 bg-white/10 text-text-inverse-subtle"
                >
                  <FilmStrip size={14} aria-hidden />
                </span>
              )}
            </li>
          ))}
        </ul>
        {more > 0 && (
          <span className="text-textXs text-text-inverse-subtle">+{more}</span>
        )}
        <span className="whitespace-nowrap text-textSmMedium text-text-inverse">
          {items.length} ready for client
        </span>
        <Button
          size="small"
          onClick={() => {
            trackApprovalRequestFormOpened({
              source: "tray",
              ready_total: items.length,
            });
            onRequest();
          }}
        >
          Request approval
        </Button>
        <Button
          variant="icon"
          size="tiny"
          aria-label="Hide until something new is ready"
          onClick={() => tuck("button")}
        >
          <Minus size={12} />
        </Button>
      </FloatingActionBar>
    </div>
  );
}
```

- [ ] **Step 5 (test): Run — passes**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvReadyForClientTray.test.tsx
```

- [ ] **Step 6 (test): Mutation checks**

1. In `isTuckedFor`, change `current.every(…)` to `current.join("|") === tucked.join("|")` → "stays tucked when a ready artboard is unmarked" fails.
2. In `readySetKeys`, drop the version (`i.subject_key` only) → "comes back for a new version of a tucked artboard" fails.
3. Delete the `if (!target.closest("[data-kv-canvas-surface]")) return;` guard's effect by removing the whole `document.addEventListener` line → "tucks on a canvas press …" fails.

- [ ] **Step 7: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/client-lane/readyTray.ts src/components/client-lane/agency/KvReadyForClientTray.tsx src/components/client-lane/agency/KvReadyForClientTray.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "readyTray|KvReadyForClientTray"
```

- [ ] **Step 8: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/client-lane/readyTray.ts src/components/client-lane/agency/KvReadyForClientTray.tsx src/components/client-lane/agency/KvReadyForClientTray.test.tsx && /usr/bin/git commit -F - <<'EOF'
feat(web): Ready-for-client tray — tucks until something new is marked

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 8: Verdict chips on boards, Resize tiles and Motion tiles

Ruling: verdicts reach canvas chrome through a context (`ArtboardVerdictsProvider`), not a prop — the board chrome sits four components below the layout (`KvCanvas → CanvasStageFrame → KvFabricCanvas → BoardChrome`) and the strip chrome two, and the data is read-only. Outside a provider the map is empty, so flag-off draws nothing. The ready chip's dark hex moves to the theme-aware `frndos-float-panel` in the same edit, so the two chips that share one slot share one surface.

**Files:**
- Create: `src/components/studio/kv-generator/KvArtboardVerdictChip.tsx`
- Create: `src/components/studio/kv-generator/KvArtboardVerdictChip.test.tsx`
- Modify: `src/components/studio/kv-generator/fabric/BoardChrome.tsx`
- Modify: `src/components/studio/kv-generator/KvResizeStripChrome.tsx`
- Modify: `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx`

**Interfaces:**
- Consumes: `ArtboardVerdict`, `VerdictChipView`, `verdictChip`, `boardSubjectKey`, `resizeSubjectKey` (Task 1); `TONE_DOT` (Task 1).
- Produces: `ArtboardVerdictsProvider({ value: ReadonlyMap<string, ArtboardVerdict>; children })`; `useArtboardVerdicts(): ReadonlyMap<string, ArtboardVerdict>`; `KvArtboardVerdictChip({ view: VerdictChipView; dense?: boolean; className?; style? })` (root carries `data-verdict={view.state}` and `aria-label="Client: {text}"`); `KvMotionTileStage` gains `verdict?: VerdictChipView | null`.

- [ ] **Step 1 (test): Write the failing test**

Create `src/components/studio/kv-generator/KvArtboardVerdictChip.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { render, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import {
  artboardVerdicts,
  verdictChip,
  type CurrentArtboardVersion,
} from "@/lib/client-lane/canvasApproval";
import {
  agencyRequest,
  requestApproval,
} from "@/lib/client-lane/requestFixtures";

import {
  ArtboardVerdictsProvider,
  KvArtboardVerdictChip,
  useArtboardVerdicts,
} from "./KvArtboardVerdictChip";

const body = () => within(document.body);

function Probe({
  subjectKey,
  current,
}: {
  subjectKey: string;
  current: CurrentArtboardVersion;
}) {
  const view = verdictChip(useArtboardVerdicts().get(subjectKey), current);
  return view ? <KvArtboardVerdictChip view={view} /> : <span>no chip</span>;
}

describe("KvArtboardVerdictChip", () => {
  it("reads the artboard's verdict from the provider", () => {
    const map = artboardVerdicts([
      agencyRequest({
        approvals: [
          requestApproval({
            subject_key: "resize:r1",
            phase: "resize",
            version_id: "r1",
            status: "changes_required",
            pin_count: 5,
          }),
        ],
      }),
    ]);
    render(
      <ArtboardVerdictsProvider value={map}>
        <Probe subjectKey="resize:r1" current={{ versionId: "r1" }} />
      </ArtboardVerdictsProvider>
    );
    const chip = body().getByLabelText("Client: New version asked · 5 pins");
    expect(chip).toHaveAttribute("data-verdict", "new_version_asked");
    expect(chip).toHaveTextContent("New version asked · 5 pins");
  });

  it("draws nothing outside a provider", () => {
    render(<Probe subjectKey="resize:r1" current={{ versionId: "r1" }} />);
    expect(body().getByText("no chip")).toBeInTheDocument();
  });
});
```

- [ ] **Step 2 (test): Run — fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvArtboardVerdictChip.test.tsx
```

- [ ] **Step 3: The chip + context**

Create `src/components/studio/kv-generator/KvArtboardVerdictChip.tsx`:

```tsx
"use client";

import clsx from "clsx";
import {
  createContext,
  useContext,
  type CSSProperties,
  type ReactNode,
} from "react";

import type {
  ArtboardVerdict,
  VerdictChipView,
} from "@/lib/client-lane/canvasApproval";
import { TONE_DOT } from "@/lib/client-lane/statusTone";

const EMPTY: ReadonlyMap<string, ArtboardVerdict> = new Map();
const ArtboardVerdictsContext =
  createContext<ReadonlyMap<string, ArtboardVerdict>>(EMPTY);

/** What the client said, per artboard key (spec 2026-10-01 §6.1). The
 *  layout and the Motion editor provide it; outside it nothing draws. */
export function ArtboardVerdictsProvider({
  value,
  children,
}: {
  value: ReadonlyMap<string, ArtboardVerdict>;
  children: ReactNode;
}) {
  return (
    <ArtboardVerdictsContext.Provider value={value}>
      {children}
    </ArtboardVerdictsContext.Provider>
  );
}

export function useArtboardVerdicts(): ReadonlyMap<string, ArtboardVerdict> {
  return useContext(ArtboardVerdictsContext);
}

/**
 * The verdict chip in an artboard's ready-chip slot: Waiting, Approved,
 * Approved with fixes, New version asked · n pins, Feedback, no decision
 * yet · n pins. Canvas chrome, not a frndOS component (spec §11.2): the
 * ready chip's own dark-pill recipe (Daffa, 2026-10-01: the chips must look
 * exactly like the existing ready chip), plus a status dot in the colour of
 * the status pill. Read-only — the status
 * popover is where it is acted on.
 */
export function KvArtboardVerdictChip({
  view,
  dense = false,
  className,
  style,
}: {
  view: VerdictChipView;
  /** Motion's label row: the tighter padding of its own chips. */
  dense?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <span
      data-verdict={view.state}
      aria-label={`Client: ${view.text}`}
      className={clsx(
        "pointer-events-none flex items-center gap-1 whitespace-nowrap rounded-full border border-white/15 bg-[rgba(26,26,26,0.85)] font-geist text-textXsMedium font-medium text-text-inverse shadow-[0_1px_6px_rgba(0,0,0,0.35)]",
        dense ? "px-1.5 py-0.5" : "px-2.5 py-1",
        className
      )}
      style={style}
    >
      <span
        aria-hidden
        className={clsx("size-1.5 shrink-0 rounded-full", TONE_DOT[view.variant])}
      />
      {view.text}
    </span>
  );
}
```

- [ ] **Step 4 (test): Run — passes**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvArtboardVerdictChip.test.tsx
```

Mutation (test): in `ArtboardVerdictsProvider`, pass `value={EMPTY}` to the context provider instead of `value={value}` → "reads the artboard's verdict from the provider" fails; restore.

- [ ] **Step 5: Ready chip stays as it is**

Do NOT restyle `ReadyToShareChip.tsx`. Daffa asked (2026-10-01) that the ready chip look exactly like the existing board chip; its dark pill (`bg-[rgba(26,26,26,0.85)]`) stays, and the verdict chip above copies it.

- [ ] **Step 6: Boards — `BoardChrome`**

In `src/components/studio/kv-generator/fabric/BoardChrome.tsx`:

1. Imports:

```ts
import { boardSubjectKey, verdictChip } from "@/lib/client-lane/canvasApproval";
import {
  KvArtboardVerdictChip,
  useArtboardVerdicts,
} from "../KvArtboardVerdictChip";
```

2. First line inside `BoardChrome(props)`, before the destructuring: `const verdicts = useArtboardVerdicts();`
3. In the board branch, directly before `const readyChipAt = …`, add

```ts
        // The client's verdict rides in the same slot, left of the ready
        // chip (spec 2026-10-01 §6.1). A promoted-concept ghost is not an
        // artboard of its own and carries neither.
        const verdict = board.isConceptPreview
          ? null
          : verdictChip(verdicts.get(boardSubjectKey(board)), {
              versionId: board.id,
            });
```

and change the `readyChipNeedsOwnRow(boardLabel, BOARD_WORLD_WIDTH)` call to `readyChipNeedsOwnRow(boardLabel, BOARD_WORLD_WIDTH, verdict ? verdict.text.length * 7 + 28 : 0)`.
4. Replace the whole `{!board.isConceptPreview && onToggleReadyToShare && ( <ReadyToShareChip … /> )}` element with:

```tsx
            {!board.isConceptPreview && (onToggleReadyToShare || verdict) && (
              <div
                className="absolute z-10 flex items-center gap-1"
                style={{
                  ...AT_ORIGIN,
                  transformOrigin: "100% 100%",
                  transform: readyChipAt,
                }}
              >
                {verdict && <KvArtboardVerdictChip view={verdict} />}
                {onToggleReadyToShare && (
                  <ReadyToShareChip
                    ready={
                      !!readyToShareIds?.length &&
                      (readyToShareIds.includes(board.id) ||
                        (board.version_ids ?? []).some((v) =>
                          readyToShareIds.includes(v)
                        ))
                    }
                    onToggle={() => onToggleReadyToShare(board.id, "chip")}
                  />
                )}
              </div>
            )}
```

5. `readyChipNeedsOwnRow` gains the extra width:

```ts
function readyChipNeedsOwnRow(
  label: string,
  availableWidth: number,
  /** World width of a verdict chip sharing the row (0 = none). */
  extraWidth = 0
): boolean {
  const ESTIMATED_CHAR_WIDTH = 8;
  const ESTIMATED_CHIP_WIDTH = 170; // widest case: "Mark ready to share" + icon + padding
  const GAP = 12;
  const extra = extraWidth > 0 ? extraWidth + 4 : 0;
  return (
    label.length * ESTIMATED_CHAR_WIDTH + ESTIMATED_CHIP_WIDTH + GAP + extra >
    availableWidth
  );
}
```

- [ ] **Step 7: Resize tiles — `KvResizeStripChrome`**

In `src/components/studio/kv-generator/KvResizeStripChrome.tsx`:

1. Imports: `import { resizeSubjectKey, verdictChip } from "@/lib/client-lane/canvasApproval";` and `import { KvArtboardVerdictChip, useArtboardVerdicts } from "./KvArtboardVerdictChip";`.
2. After `const rootRef = useRef<HTMLDivElement | null>(null);` add `const verdicts = useArtboardVerdicts();`.
3. Replace the `{onToggleReadyToShare && tileHasUsableImage(row) && ( <div className="flex h-6 items-end"> <ReadyToShareChip … style={TILE_READY_CHIP_STYLE} /> </div> )}` block with:

```tsx
                      {(() => {
                        // The client's verdict sits left of the ready chip,
                        // both on the board chip's scale (spec 2026-10-01
                        // §6.1: Resize had no on-canvas verdict). A tile is
                        // regenerated IN PLACE, so its image is what tells a
                        // new version from the approved one.
                        const verdict = verdictChip(
                          verdicts.get(resizeSubjectKey(row.id)),
                          { versionId: row.id, imageUrl: row.imageUrl }
                        );
                        const canMark =
                          !!onToggleReadyToShare && tileHasUsableImage(row);
                        if (!verdict && !canMark) return null;
                        return (
                          // As tall as the icons (h-6), bottom-aligned.
                          <div className="flex h-6 items-end">
                            <div
                              className="flex items-center gap-1"
                              style={TILE_READY_CHIP_STYLE}
                            >
                              {verdict && (
                                <KvArtboardVerdictChip view={verdict} />
                              )}
                              {canMark && (
                                <ReadyToShareChip
                                  ready={!!readyToShareIds?.includes(row.id)}
                                  onToggle={() => onToggleReadyToShare(row)}
                                />
                              )}
                            </div>
                          </div>
                        );
                      })()}
```

(`onToggleReadyToShare` is narrowed by `canMark` only at runtime; if tsc complains that it may be undefined inside the arrow, write `onToggle={() => onToggleReadyToShare?.(row)}`.)

- [ ] **Step 8: Motion tiles — `KvMotionTileStage`**

In `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx`:

1. Imports: `import type { VerdictChipView } from "@/lib/client-lane/canvasApproval";` and `import { KvArtboardVerdictChip } from "../KvArtboardVerdictChip";`.
2. In `Props`, after `readyToShare?: …;` add

```ts
  /** The client's verdict on THIS size (spec 2026-10-01 §6.1), drawn left
   *  of the ready chip in the label row. Null draws nothing. */
  verdict?: VerdictChipView | null;
```

and destructure `verdict = null,` after `readyToShare = null,`.
3. In the label row, directly before `{readyToShare && (`, add `{verdict && <KvArtboardVerdictChip view={verdict} dense />}`.
4. Leave the ready button's classes unchanged (the ready chip keeps its existing look — Daffa, 2026-10-01).

- [ ] **Step 9 (test): Regression**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/stripChromeStyles.test.ts && bun test src/components/studio/kv-generator/KvCanvas.test.tsx
```

Expected: the same results as before this task (run each once on the Task 0 tip with `/usr/bin/git show HEAD~N:…` only if a failure needs a baseline — never stash).

- [ ] **Step 10: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/studio/kv-generator/KvArtboardVerdictChip.tsx src/components/studio/kv-generator/KvArtboardVerdictChip.test.tsx src/components/studio/kv-generator/ReadyToShareChip.tsx src/components/studio/kv-generator/fabric/BoardChrome.tsx src/components/studio/kv-generator/KvResizeStripChrome.tsx src/components/studio/kv-generator/motion/KvMotionTileStage.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "KvArtboardVerdictChip|ReadyToShareChip|BoardChrome|KvResizeStripChrome|KvMotionTileStage" ; /usr/bin/grep -n "rgba(26,26,26" src/components/studio/kv-generator/ReadyToShareChip.tsx src/components/studio/kv-generator/motion/KvMotionTileStage.tsx
```

Expected: eslint clean; both greps print nothing.

- [ ] **Step 11: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/studio/kv-generator/KvArtboardVerdictChip.tsx src/components/studio/kv-generator/KvArtboardVerdictChip.test.tsx src/components/studio/kv-generator/ReadyToShareChip.tsx src/components/studio/kv-generator/fabric/BoardChrome.tsx src/components/studio/kv-generator/KvResizeStripChrome.tsx src/components/studio/kv-generator/motion/KvMotionTileStage.tsx && /usr/bin/git commit -F - <<'EOF'
feat(web): client verdict chips on boards, resize tiles and motion tiles

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 9: Focus API `selectSurface` and `useArtboardJump`

**Files:**
- Modify: `src/components/studio/kv-generator/focusCamera.ts`
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx`
- Create: `src/components/studio/kv-generator/useArtboardJump.ts`
- Create: `src/components/studio/kv-generator/useArtboardJump.test.tsx`

**Interfaces:**
- Consumes: `planArtboardJump`, `ArtboardJumpTarget`, `ArtboardJumpPlan` (Task 1); `anchorVersion` (`@/lib/comments/anchorCodec`).
- Produces: `KvFocusApi.selectSurface?: (surfaceId: string) => void`; and

```ts
export interface ArtboardJumpDeps {
  canvasMode: LiveCanvasMode;
  /** Surfaces the canvas has drawn: board tips and strip tile row ids. */
  surfaceRects: Record<string, unknown>;
  threads: CommentThread[];
  resolveTip: (generationId: string) => string | null;
  switchMode: (mode: "sketch" | "craft") => void;
  selectSurface: (surfaceId: string) => void;
  focusSurface: (surfaceId: string) => void;
  /** Opens the Comments dock on a thread. */
  openPins: (threadId: string) => void;
  openMotion: (projectId: string, ratio: string, subjectKey: string) => void;
  onMissing: () => void;
  /** Give up after this long when the surface never renders. Default 3000. */
  missingAfterMs?: number;
}
export function useArtboardJump(deps: ArtboardJumpDeps): (target: ArtboardJumpTarget) => void;
```

- [ ] **Step 1: `selectSurface` on the focus API**

In `src/components/studio/kv-generator/focusCamera.ts`, add to `KvFocusApi` after `focusBoard`:

```ts
  /** Make a surface the selected one — a Craft board (as a board click does)
   *  or a Resize strip tile. The approval status popover's jump uses it
   *  (spec 2026-10-01 §6.1 "selects it"). Absent on canvases without
   *  surfaces (the Konva fallback). */
  selectSurface?: (surfaceId: string) => void;
```

In `src/components/studio/kv-generator/KvFabricCanvas.tsx`, next to `const focusBoardFnRef = useRef(focusBoard); focusBoardFnRef.current = focusBoard;` add

```ts
  const selectSurfaceFnRef = useRef(selectSurface);
  selectSurfaceFnRef.current = selectSurface;
```

and inside the `onFocusApiChange({ … })` object, after `focusBoard: …,` add `selectSurface: (id) => selectSurfaceFnRef.current(id),`. (`selectSurface` is the `useCallback` that routes a board id to `onSelectBoard` and a tile id to `onSelectSurface`; it is declared above this point.)

- [ ] **Step 2 (test): Write the failing tests**

Create `src/components/studio/kv-generator/useArtboardJump.test.tsx`:

```tsx
import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { buildPinAnchor } from "@/lib/comments/anchorCodec";
import type { CommentThread, CommentableType } from "@/types/comments";

import { useArtboardJump, type ArtboardJumpDeps } from "./useArtboardJump";

function thread(id: string, version: string, createdAt: string): CommentThread {
  return {
    parent: {
      id,
      commentableType: "studio_file" as CommentableType,
      commentableId: "f1",
      anchor: buildPinAnchor(
        { stage: "craft", version, part: `board.${version}` },
        0.5,
        0.5
      ),
      parentId: null,
      author: { id: "u1", name: "Dina" },
      body: "note",
      mentions: [],
      internalOnly: false,
      resolvedAt: null,
      resolvedById: null,
      createdAt,
      updatedAt: createdAt,
    },
    replies: [],
  };
}

const TIPS: Record<string, string> = { g0: "g3", g3: "g3" };

function setup(overrides: Partial<ArtboardJumpDeps> = {}) {
  const deps: ArtboardJumpDeps = {
    canvasMode: "craft",
    surfaceRects: {},
    threads: [],
    resolveTip: (id) => TIPS[id] ?? null,
    switchMode: vi.fn(),
    selectSurface: vi.fn(),
    focusSurface: vi.fn(),
    openPins: vi.fn(),
    openMotion: vi.fn(),
    onMissing: vi.fn(),
    missingAfterMs: 40,
    ...overrides,
  };
  const hook = renderHook((p: ArtboardJumpDeps) => useArtboardJump(p), {
    initialProps: deps,
  });
  return { deps, ...hook };
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("useArtboardJump", () => {
  it("lands on a board's current tip and opens its newest pin", () => {
    const { deps, result } = setup({
      surfaceRects: { g3: {} },
      threads: [
        thread("t1", "g3", "2026-10-01T09:00:00.000Z"),
        thread("t2", "g3", "2026-10-01T10:00:00.000Z"),
        thread("t3", "g9", "2026-10-01T11:00:00.000Z"),
      ],
    });
    act(() =>
      result.current({ subjectKey: "board:g0", phase: "craft", versionId: "g3" })
    );
    expect(deps.switchMode).not.toHaveBeenCalled();
    expect(deps.selectSurface).toHaveBeenCalledWith("g3");
    expect(deps.focusSurface).toHaveBeenCalledWith("g3");
    expect(deps.openPins).toHaveBeenCalledWith("t2");
  });

  it("switches to Craft before landing on a resize tile", () => {
    const { deps, result, rerender } = setup({ canvasMode: "sketch" });
    act(() =>
      result.current({ subjectKey: "resize:r1", phase: "resize", versionId: "r1" })
    );
    expect(deps.switchMode).toHaveBeenCalledWith("craft");
    expect(deps.focusSurface).not.toHaveBeenCalled();
    rerender({ ...deps, canvasMode: "craft", surfaceRects: { r1: {} } });
    expect(deps.selectSurface).toHaveBeenCalledWith("r1");
    expect(deps.focusSurface).toHaveBeenCalledWith("r1");
    expect(deps.openPins).not.toHaveBeenCalled();
  });

  it("hands a motion clip to the Motion editor", () => {
    const { deps, result } = setup();
    act(() =>
      result.current({
        subjectKey: "motion:01P:9:16",
        phase: "motion",
        versionId: "m2",
      })
    );
    expect(deps.openMotion).toHaveBeenCalledWith("01P", "9:16", "motion:01P:9:16");
  });

  it("gives up with a toast when the artboard never renders", async () => {
    const { deps, result, rerender } = setup();
    act(() =>
      result.current({ subjectKey: "board:gone", phase: "craft", versionId: null })
    );
    await waitFor(() => expect(deps.onMissing).toHaveBeenCalledTimes(1));
    rerender({ ...deps, surfaceRects: { gone: {} } });
    expect(deps.focusSurface).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 3 (test): Run — fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/useArtboardJump.test.tsx
```

- [ ] **Step 4: Implement**

Create `src/components/studio/kv-generator/useArtboardJump.ts`:

```ts
"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import {
  planArtboardJump,
  type ArtboardJumpPlan,
  type ArtboardJumpTarget,
} from "@/lib/client-lane/canvasApproval";
import { anchorVersion } from "@/lib/comments/anchorCodec";
import type { LiveCanvasMode } from "@/lib/studio/kv/seedCanvasMode";
import type { CommentThread } from "@/types/comments";

type SurfacePlan = Extract<ArtboardJumpPlan, { kind: "surface" }>;

export interface ArtboardJumpDeps {
  canvasMode: LiveCanvasMode;
  /** Surfaces the canvas has drawn: board tips and strip tile row ids. */
  surfaceRects: Record<string, unknown>;
  threads: CommentThread[];
  resolveTip: (generationId: string) => string | null;
  switchMode: (mode: "sketch" | "craft") => void;
  selectSurface: (surfaceId: string) => void;
  focusSurface: (surfaceId: string) => void;
  /** Opens the Comments dock on a thread. */
  openPins: (threadId: string) => void;
  openMotion: (projectId: string, ratio: string, subjectKey: string) => void;
  onMissing: () => void;
  /** Give up after this long when the surface never renders. Default 3000. */
  missingAfterMs?: number;
}

/** The newest thread left on that version — "its pins" (spec §6.1). */
function newestThreadOn(
  threads: CommentThread[],
  versionId: string
): CommentThread | null {
  let best: CommentThread | null = null;
  for (const t of threads) {
    if (anchorVersion(t.parent.anchor) !== versionId) continue;
    if (!best || t.parent.createdAt > best.parent.createdAt) best = t;
  }
  return best;
}

/**
 * A status-popover row → the artboard (spec 2026-10-01 §6.1): switch to the
 * tab it lives on, select it, centre it, and open its pins in the Comments
 * dock when it has any. A mode switch re-renders the canvas, so the landing
 * waits until the surface has a rect; one that never appears (removed since)
 * gives up with `onMissing` rather than jumping seconds later.
 */
export function useArtboardJump(
  deps: ArtboardJumpDeps
): (target: ArtboardJumpTarget) => void {
  const depsRef = useRef(deps);
  depsRef.current = deps;
  const [pending, setPending] = useState<SurfacePlan | null>(null);

  const land = useCallback((plan: SurfacePlan) => {
    const d = depsRef.current;
    d.selectSurface(plan.surfaceId);
    d.focusSurface(plan.surfaceId);
    const thread = newestThreadOn(d.threads, plan.pinVersionId);
    if (thread) d.openPins(thread.parent.id);
  }, []);

  const jump = useCallback(
    (target: ArtboardJumpTarget) => {
      const d = depsRef.current;
      const plan = planArtboardJump(target, d.resolveTip);
      if (plan.kind === "none") {
        d.onMissing();
        return;
      }
      if (plan.kind === "motion") {
        d.openMotion(plan.projectId, plan.ratio, target.subjectKey);
        return;
      }
      if (d.canvasMode === plan.mode && d.surfaceRects[plan.surfaceId]) {
        setPending(null);
        land(plan);
        return;
      }
      if (d.canvasMode !== plan.mode) d.switchMode(plan.mode);
      setPending(plan);
    },
    [land]
  );

  const { canvasMode, surfaceRects, missingAfterMs = 3000 } = deps;

  // Land once the tab is right and the surface is drawn.
  useEffect(() => {
    if (!pending) return;
    if (canvasMode !== pending.mode || !surfaceRects[pending.surfaceId]) return;
    setPending(null);
    land(pending);
  }, [pending, canvasMode, surfaceRects, land]);

  // …or give up.
  useEffect(() => {
    if (!pending) return;
    const timer = window.setTimeout(() => {
      setPending(null);
      depsRef.current.onMissing();
    }, missingAfterMs);
    return () => window.clearTimeout(timer);
  }, [pending, missingAfterMs]);

  return jump;
}
```

- [ ] **Step 5 (test): Run — passes**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/useArtboardJump.test.tsx
```

- [ ] **Step 6 (test): Mutation checks**

1. In `jump`, delete `if (d.canvasMode !== plan.mode) d.switchMode(plan.mode);` → "switches to Craft before landing on a resize tile" fails.
2. Delete the whole give-up effect → "gives up with a toast when the artboard never renders" fails.
3. In `newestThreadOn`, flip `>` to `<` → "lands on a board's current tip and opens its newest pin" fails.

- [ ] **Step 7: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/studio/kv-generator/focusCamera.ts src/components/studio/kv-generator/KvFabricCanvas.tsx src/components/studio/kv-generator/useArtboardJump.ts src/components/studio/kv-generator/useArtboardJump.test.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "focusCamera|KvFabricCanvas|useArtboardJump"
```

- [ ] **Step 8: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/studio/kv-generator/focusCamera.ts src/components/studio/kv-generator/KvFabricCanvas.tsx src/components/studio/kv-generator/useArtboardJump.ts src/components/studio/kv-generator/useArtboardJump.test.tsx && /usr/bin/git commit -F - <<'EOF'
feat(web): jump from an approval row to its artboard — mode, select, centre, pins

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 10: Hover frame around the ready set, and an edge pointer

**Files:**
- Create: `src/lib/studio/kv/readySetFrame.ts`
- Create: `src/lib/studio/kv/readySetFrame.test.ts`
- Create: `src/components/studio/kv-generator/KvReadySetFrame.tsx`

**Interfaces:**
- Consumes: `Camera` (`@/lib/canvas/cameraStore`), `TOP_NAV_SAFE_PX`, `BOTTOM_TOOLBAR_SAFE_PX` (`@/lib/studio/kv/canvasSafeZones`), `useCameraCssVars`, `worldTranslate`, `lenCss`.
- Produces: `type WorldRect = { x; y; width; height }`; `unionRect(rects: WorldRect[]): WorldRect | null`; `interface EdgePointer { x: number; y: number; angleDeg: number }`; `edgePointer(union, camera, viewport: { width; height }, inset?): EdgePointer | null`; `KvReadySetFrame({ rects: WorldRect[]; cameraStore: CameraStore | null })`.

Ruling: the edge pointer is computed from the camera at the moment hover starts (`cameraStore.get()`); the frames themselves follow every pan through the camera CSS variables. A hover is a second long — re-deriving the pointer per camera frame would re-render React on every pan for no gain.

- [ ] **Step 1 (test): Write the failing test**

Create `src/lib/studio/kv/readySetFrame.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { edgePointer, unionRect } from "./readySetFrame";

const cam = { scale: 1, x: 0, y: 0 };
const view = { width: 1000, height: 800 };
const inset = { top: 80, bottom: 104, side: 24 };

describe("edgePointer", () => {
  it("draws no pointer while any part of the set is on screen", () => {
    expect(
      edgePointer({ x: 100, y: 100, width: 100, height: 100 }, cam, view, inset)
    ).toBeNull();
  });

  it("points right from the right edge", () => {
    const p = edgePointer(
      { x: 3000, y: 338, width: 100, height: 100 },
      cam,
      view,
      inset
    );
    expect(p?.x).toBeCloseTo(976);
    expect(p?.y).toBeCloseTo(388);
    expect(p?.angleDeg).toBeCloseTo(0);
  });

  it("points up from under the top bar", () => {
    const p = edgePointer(
      { x: 450, y: -1000, width: 100, height: 100 },
      cam,
      view,
      inset
    );
    expect(p?.x).toBeCloseTo(500);
    expect(p?.y).toBeCloseTo(80);
    expect(p?.angleDeg).toBeCloseTo(-90);
  });

  it("unions the set's rects", () => {
    expect(
      unionRect([
        { x: 0, y: 0, width: 10, height: 10 },
        { x: 20, y: -5, width: 10, height: 10 },
      ])
    ).toEqual({ x: 0, y: -5, width: 30, height: 15 });
    expect(unionRect([])).toBeNull();
  });
});
```

- [ ] **Step 2 (test): Run — fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/studio/kv/readySetFrame.test.ts
```

- [ ] **Step 3: Implement the math**

Create `src/lib/studio/kv/readySetFrame.ts`:

```ts
/**
 * Hovering "Ready for client" frames the ready artboards on the canvas, or —
 * when none of them is on screen — points at them from the edge (spec
 * 2026-10-01 §6.1). Pure: world rects + camera in, screen pointer out.
 */
import type { Camera } from "@/lib/canvas/cameraStore";

import { BOTTOM_TOOLBAR_SAFE_PX, TOP_NAV_SAFE_PX } from "./canvasSafeZones";

export type WorldRect = { x: number; y: number; width: number; height: number };

export function unionRect(rects: WorldRect[]): WorldRect | null {
  if (rects.length === 0) return null;
  const left = Math.min(...rects.map((r) => r.x));
  const top = Math.min(...rects.map((r) => r.y));
  const right = Math.max(...rects.map((r) => r.x + r.width));
  const bottom = Math.max(...rects.map((r) => r.y + r.height));
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export interface EdgePointer {
  /** Screen position inside the canvas viewport. */
  x: number;
  y: number;
  /** Direction to the set: 0 = right, 90 = down, -90 = up. */
  angleDeg: number;
}

/**
 * Null while any part of the set is inside the usable viewport (between the
 * top bar and the bottom nav). Otherwise the point where the ray from the
 * viewport's centre to the set's centre leaves that box.
 */
export function edgePointer(
  union: WorldRect,
  camera: Camera,
  viewport: { width: number; height: number },
  inset: { top: number; bottom: number; side: number } = {
    top: TOP_NAV_SAFE_PX,
    bottom: BOTTOM_TOOLBAR_SAFE_PX,
    side: 24,
  }
): EdgePointer | null {
  const left = union.x * camera.scale + camera.x;
  const top = union.y * camera.scale + camera.y;
  const right = left + union.width * camera.scale;
  const bottom = top + union.height * camera.scale;
  const box = {
    l: inset.side,
    t: inset.top,
    r: viewport.width - inset.side,
    b: viewport.height - inset.bottom,
  };
  if (right > box.l && left < box.r && bottom > box.t && top < box.b) {
    return null;
  }
  const cx = (box.l + box.r) / 2;
  const cy = (box.t + box.b) / 2;
  const dx = (left + right) / 2 - cx;
  const dy = (top + bottom) / 2 - cy;
  const t = Math.min(
    dx === 0 ? Infinity : (box.r - box.l) / 2 / Math.abs(dx),
    dy === 0 ? Infinity : (box.b - box.t) / 2 / Math.abs(dy)
  );
  return {
    x: cx + dx * t,
    y: cy + dy * t,
    angleDeg: (Math.atan2(dy, dx) * 180) / Math.PI,
  };
}
```

- [ ] **Step 4 (test): Run — passes; mutation**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/studio/kv/readySetFrame.test.ts
```

Mutation (test): replace `Math.min(` with `Math.max(` in the `t` computation → "points right from the right edge" fails; restore.

- [ ] **Step 5: The overlay**

Create `src/components/studio/kv-generator/KvReadySetFrame.tsx`:

```tsx
"use client";

import { ArrowRight } from "@phosphor-icons/react";
import { useLayoutEffect, useRef, useState } from "react";

import { useCameraCssVars } from "@/lib/canvas/cameraCssVars";
import type { CameraStore } from "@/lib/canvas/cameraStore";
import { lenCss, worldTranslate } from "@/lib/canvas/worldOverlay";
import {
  edgePointer,
  unionRect,
  type EdgePointer,
  type WorldRect,
} from "@/lib/studio/kv/readySetFrame";

/**
 * While "Ready for client" is hovered: a frame around each ready artboard
 * on the canvas (the `ObjectSelectChrome` overlay idea), or one pointer at
 * the edge when none is on screen (spec 2026-10-01 §6.1). World overlay
 * (docs/adr/0005): the root binds the camera CSS variables, so the frames
 * move with a pan in the same event. The root ALWAYS renders — the binding
 * runs once per (element, store) pair.
 */
export function KvReadySetFrame({
  rects,
  cameraStore,
}: {
  rects: WorldRect[];
  cameraStore: CameraStore | null;
}) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  useCameraCssVars(rootRef, cameraStore);
  const [pointer, setPointer] = useState<
    (EdgePointer & { left: number; top: number }) | null
  >(null);

  useLayoutEffect(() => {
    const union = unionRect(rects);
    const surface = document
      .querySelector("[data-kv-canvas-surface]")
      ?.getBoundingClientRect();
    if (!union || !cameraStore || !surface) {
      setPointer(null);
      return;
    }
    const p = edgePointer(union, cameraStore.get(), {
      width: surface.width,
      height: surface.height,
    });
    setPointer(
      p ? { ...p, left: surface.left + p.x, top: surface.top + p.y } : null
    );
  }, [rects, cameraStore]);

  return (
    <div
      ref={rootRef}
      aria-hidden
      className="pointer-events-none fixed inset-0 z-20"
    >
      {cameraStore &&
        rects.map((r, i) => (
          <div
            key={i}
            className="absolute rounded-md border-2 border-white/70"
            style={{
              left: 0,
              top: 0,
              transform: worldTranslate(
                { world: r.x, px: -4 },
                { world: r.y, px: -4 }
              ),
              width: lenCss({ world: r.width, px: 8 }),
              height: lenCss({ world: r.height, px: 8 }),
            }}
          />
        ))}
      {pointer && (
        <div
          className="frndos-float-panel fixed flex items-center gap-1 rounded-full border border-white/10 px-2 py-1 font-geist text-textXsMedium text-text-inverse"
          style={{
            left: pointer.left,
            top: pointer.top,
            transform: "translate(-50%, -50%)",
          }}
        >
          <ArrowRight
            size={12}
            style={{ transform: `rotate(${pointer.angleDeg}deg)` }}
          />
          Off screen
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 6: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/lib/studio/kv/readySetFrame.ts src/lib/studio/kv/readySetFrame.test.ts src/components/studio/kv-generator/KvReadySetFrame.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "readySetFrame|KvReadySetFrame"
```

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/lib/studio/kv/readySetFrame.ts src/lib/studio/kv/readySetFrame.test.ts src/components/studio/kv-generator/KvReadySetFrame.tsx && /usr/bin/git commit -F - <<'EOF'
feat(web): hovering Ready for client frames the set, or points at it off screen

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 11: Wire the KV editor (`KvCanvasTopNav` + `KvGeneratorLayout`)

Rulings for this task:
- **`compact`** is set by the comment dock (as today) **and by a docked chat** (`chatDockReserve > 0`). The transform/properties panel is NOT a narrowing case: it floats `bottom: 96` with `max-height: min(640px, 100vh - 200px)`, so its top edge is always ≥ 104px from the top and never reaches the 80px bar.
- **Off for the standalone Resizer** (`standaloneResizer`) — no client approval surface there.
- The tray shows only in Concept / Craft (it sits above the bottom nav of a canvas) and not during Version History.

**Files:**
- Modify: `src/components/studio/kv-generator/KvCanvasTopNav.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx`

**Interfaces:**
- Consumes: everything from Tasks 1, 5–10.
- Produces: `KvCanvasTopNav` prop `clientSlot?: React.ReactNode`; the canvas wrapper carries `data-kv-canvas-surface`; the layout consumes `?focus_artboard=&focus_phase=` once.

- [ ] **Step 1: Top nav slot**

In `src/components/studio/kv-generator/KvCanvasTopNav.tsx`:
- add to `Props` (after `compact?`):

```ts
  /**
   * Client lane Part B (spec 2026-10-01 §6.1): the "Ready for client" /
   * approval-status slot, left of the avatars. A node, so this v1 file never
   * imports the v2 slot; the host decides whether it exists (flag, file).
   */
  clientSlot?: React.ReactNode;
```

- destructure `clientSlot,` after `compact = false,`;
- in the right zone, make the slot the first child: change

```tsx
      <div className="flex flex-1 items-center justify-end gap-6">
        <PresenceAvatars
```

to

```tsx
      <div className="flex flex-1 items-center justify-end gap-6">
        {clientSlot}
        <PresenceAvatars
```

- [ ] **Step 2: Layout imports**

In `src/components/studio/kv-generator/KvGeneratorLayout.tsx`, change `import { useApprovalVersionLabels } from "@/services/client-lane";` to

```ts
import {
  useApprovalRequests,
  useApprovalVersionLabels,
  type ApprovalRequestPreviewItem,
} from "@/services/client-lane";
```

and add

```ts
import { KvClientApprovalSlot } from "@/components/client-lane/agency/KvClientApprovalSlot";
import { KvReadyForClientTray } from "@/components/client-lane/agency/KvReadyForClientTray";
import {
  artboardHref,
  artboardVerdicts,
  focusParamOf,
  type ArtboardVerdict,
} from "@/lib/client-lane/canvasApproval";
import { ArtboardVerdictsProvider } from "./KvArtboardVerdictChip";
import { KvReadySetFrame } from "./KvReadySetFrame";
import { useArtboardJump } from "./useArtboardJump";
```

and, at module level next to the other module constants (above the component), `const EMPTY_VERDICTS: ReadonlyMap<string, ArtboardVerdict> = new Map();`.

- [ ] **Step 3: The Part B block**

Insert this block **directly after the `handleCanvasModeChange` `useCallback`** (search `const handleCanvasModeChange = useCallback(` and go to its closing `);`). It must sit there, not earlier: it passes `handleCanvasModeChange`, `handleSelectThread` and `showToast` by value, and all three are declared above that point.

```ts
  // ── Client lane Part B (spec 2026-10-01 §6.1) ───────────────────────────
  // The top-bar slot, the ready tray, the hover frame and the verdict chips
  // read the same request queries the Share dialog reads, so their counts
  // agree. Off for the standalone Resizer.
  const clientApprovalOn =
    clientLaneOn && Boolean(liveFileId) && !standaloneResizer;
  const approvalRequests = useApprovalRequests(
    clientApprovalOn ? liveFileId : null
  );
  const artboardVerdictMap = useMemo(
    () =>
      clientApprovalOn
        ? artboardVerdicts(approvalRequests.data ?? [])
        : EMPTY_VERDICTS,
    [clientApprovalOn, approvalRequests.data]
  );
  const [requestFormOpen, setRequestFormOpen] = useState(false);
  const [readySetHover, setReadySetHover] = useState<
    ApprovalRequestPreviewItem[] | null
  >(null);
  const readySetRects = useMemo(() => {
    if (!readySetHover) return [];
    const canvasState = docCanvasState ?? file?.metadata?.kv_canvas ?? null;
    return readySetHover
      .map(
        (item) =>
          boardWorldRects[
            owningBoardTip(canvasState, item.version_id) ?? item.version_id
          ]
      )
      .filter((r): r is NonNullable<typeof r> => Boolean(r));
  }, [readySetHover, boardWorldRects, docCanvasState, file?.metadata?.kv_canvas]);

  const jumpToArtboard = useArtboardJump({
    canvasMode,
    surfaceRects: boardWorldRects,
    threads: commentThreads,
    resolveTip: (id) =>
      owningBoardTip(docCanvasState ?? file?.metadata?.kv_canvas ?? null, id),
    switchMode: (mode) => handleCanvasModeChange(mode, { keepPin: true }),
    selectSurface: (id) => focusApiRef.current?.selectSurface?.(id),
    focusSurface: (id) => {
      focusApiRef.current?.focusBoard?.(id);
    },
    openPins: (threadId) => {
      // Arm the TOOL, as the `?comment=` deep link does: the tool effect is
      // the one definition of "comment dock open".
      setCanvasTool("comment");
      handleSelectThread(threadId, { fromPanel: true });
    },
    openMotion: (_projectId, _ratio, subjectKey) => {
      if (!brandId) return;
      router.push(
        artboardHref({ brandId, fileId, subjectKey, phase: "motion" })
      );
    },
    onMissing: () =>
      showToast(
        "Couldn't find that artboard",
        "It may have been removed from the canvas.",
        "info"
      ),
  });

  // `?focus_artboard=` — the Motion editor's popover links here for boards
  // and tiles. Consumed once, after the canvas state loads, then stripped.
  const consumedFocusArtboard = useRef<string | null>(null);
  useEffect(() => {
    if (!clientApprovalOn) return;
    const target = focusParamOf(searchParams);
    if (!target || consumedFocusArtboard.current === target.subjectKey) return;
    if (!docCanvasState && !file?.metadata?.kv_canvas) return;
    consumedFocusArtboard.current = target.subjectKey;
    jumpToArtboard(target);
    const next = new URLSearchParams(searchParams?.toString() ?? "");
    next.delete("focus_artboard");
    next.delete("focus_phase");
    const qs = next.toString();
    router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false });
  }, [
    clientApprovalOn,
    searchParams,
    docCanvasState,
    file?.metadata?.kv_canvas,
    jumpToArtboard,
    router,
    pathname,
  ]);
```

If `tsc` reports any of `boardWorldRects`, `commentThreads`, `focusApiRef`, `setCanvasTool`, `handleSelectThread`, `showToast`, `router`, `pathname`, `searchParams`, `brandId` as used-before-declaration, move the whole block further down (still above `return (`) until it is after all of them — never move those declarations.

- [ ] **Step 4: `compact` + the slot on the top nav**

Directly after `const chatDockReserve = chatDockInset({ … });` add

```ts
  // The bar is narrowed by the comment dock or a docked chat; the slot (and
  // the title) go compact then (spec §6.1). The properties panel never
  // reaches the bar (bottom-anchored, max-height 100vh − 200px).
  const compactTopNav =
    Boolean(commentPanelOpen && commentContext) || chatDockReserve > 0;
```

In the `<KvCanvasTopNav … />` props, replace `compact={Boolean(commentPanelOpen && commentContext)}` with `compact={compactTopNav}` (update its comment to mention the docked chat) and add:

```tsx
              clientSlot={
                clientApprovalOn && liveFileId ? (
                  <KvClientApprovalSlot
                    fileId={liveFileId}
                    fileName={title}
                    brandId={brandId}
                    compact={compactTopNav}
                    surface="canvas"
                    formOpen={requestFormOpen}
                    onFormOpenChange={setRequestFormOpen}
                    onHoverReadySet={setReadySetHover}
                    onJump={(approval) =>
                      jumpToArtboard({
                        subjectKey: approval.subject_key,
                        phase: approval.phase,
                        versionId: approval.version_id,
                      })
                    }
                  />
                ) : undefined
              }
```

- [ ] **Step 5: Canvas surface marker + verdict provider**

Find the canvas wrapper `<div className="absolute inset-0 overflow-hidden">` that directly precedes `{standaloneResizer && !viewedGeneration ? (`; add `data-kv-canvas-surface` to it (the tray's "canvas press" and the frame's viewport read it). Then wrap the `<KvCanvas … />` element inside that branch:

```tsx
              <ArtboardVerdictsProvider value={artboardVerdictMap}>
                <KvCanvas
                  …unchanged props…
                />
              </ArtboardVerdictsProvider>
```

- [ ] **Step 6: Tray + frame**

Directly after the `{commentContext && ( <CommentPinOverlay … /> )}` element add:

```tsx
        {clientApprovalOn && readySetRects.length > 0 && (
          <KvReadySetFrame
            rects={readySetRects}
            cameraStore={canvasCameraStore}
          />
        )}
```

Directly before the "Floating bottom nav" wrapper (`{/* Floating bottom nav — overlays the canvas. …`) add:

```tsx
        {clientApprovalOn &&
          liveFileId &&
          (canvasMode === "sketch" || canvasMode === "craft") &&
          !versionHistoryOpen && (
            <KvReadyForClientTray
              fileId={liveFileId}
              suppressed={requestFormOpen}
              onRequest={() => setRequestFormOpen(true)}
            />
          )}
```

- [ ] **Step 7: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/studio/kv-generator/KvCanvasTopNav.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "KvCanvasTopNav|KvGeneratorLayout" ; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: eslint clean. `KvGeneratorLayout.tsx` carried **1** pre-existing error at the multi-item base (track file "Baselines") — the grep may print that one line and nothing else; the total stays at the Task 0 baseline.

- [ ] **Step 8 (test): Regression**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvCanvas.test.tsx && bun test src/components/studio/kv-generator/KvCanvasBottomNav.test.tsx
```

- [ ] **Step 9: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/studio/kv-generator/KvCanvasTopNav.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx && /usr/bin/git commit -F - <<'EOF'
feat(web): KV editor — client slot, ready tray, hover frame, verdicts, artboard jumps

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 12: Wire the Motion editor

Rulings: the Motion editor gets the slot (spec "also in `KvMotionEditor`'s top bar") and verdict chips on its tiles; it gets **no tray** (it has no `KvCanvasBottomNav` to sit above) and **no hover frame** (its tiles are always all on screen side by side). A popover row for a size of THIS project focuses that tile; any other row navigates (boards / tiles → the KV editor, another project → that project) through `?focus_artboard=`. The Motion editor has no Comments dock, so a motion jump selects the tile and opens nothing.

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx`

**Interfaces:**
- Consumes: `useClientLaneEnabled` (`@/lib/featureFlags`), `useApprovalRequests`, `KvClientApprovalSlot`, `artboardVerdicts`, `verdictChip`, `motionSubjectKey`, `parseSubjectKey`, `artboardHref`, `focusParamOf`.
- Produces: `MotionEditorCanvas` takes `brandId: string`.

- [ ] **Step 1: Pass `brandId` down**

In `KvMotionEditor`'s return, add `brandId={brandId}` to `<MotionEditorCanvas …/>`; add `brandId: string;` to `MotionEditorCanvas`'s prop type and destructure it.

- [ ] **Step 2: Imports**

Add:

```ts
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { KvClientApprovalSlot } from "@/components/client-lane/agency/KvClientApprovalSlot";
import {
  artboardHref,
  artboardVerdicts,
  focusParamOf,
  motionSubjectKey,
  parseSubjectKey,
  verdictChip,
} from "@/lib/client-lane/canvasApproval";
import { useClientLaneEnabled } from "@/lib/featureFlags";
import {
  useApprovalRequests,
  type AgencyRequestApproval,
} from "@/services/client-lane";
```

- [ ] **Step 3: State, verdicts, jump, deep link**

Inside `MotionEditorCanvas`, **directly after** the `const [focusedTileKey, setFocusedTileKey] = useState<string | null>(null);` line and the effect/statement that immediately follows it, add:

```ts
  // ── Client lane Part B (spec 2026-10-01 §6.1) ───────────────────────────
  const clientLane = useClientLaneEnabled();
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [requestFormOpen, setRequestFormOpen] = useState(false);
  const approvalRequests = useApprovalRequests(clientLane ? fileId : null);
  const verdicts = useMemo(
    () => artboardVerdicts(approvalRequests.data ?? []),
    [approvalRequests.data]
  );

  const handleApprovalJump = useCallback(
    (approval: AgencyRequestApproval) => {
      const parsed = parseSubjectKey(approval.subject_key);
      if (parsed?.kind === "motion" && parsed.projectId === projectId) {
        setFocusedTileKey(parsed.ratio);
        return;
      }
      router.push(
        artboardHref({
          brandId,
          fileId,
          subjectKey: approval.subject_key,
          phase: approval.phase,
        })
      );
    },
    [projectId, router, brandId, fileId]
  );

  // `?focus_artboard=motion:{this project}:{ratio}` from the KV editor's
  // popover: focus that size once, then strip the param.
  const consumedFocusArtboard = useRef<string | null>(null);
  useEffect(() => {
    const target = focusParamOf(searchParams);
    if (!target || consumedFocusArtboard.current === target.subjectKey) return;
    consumedFocusArtboard.current = target.subjectKey;
    const parsed = parseSubjectKey(target.subjectKey);
    if (parsed?.kind === "motion" && parsed.projectId === projectId) {
      setFocusedTileKey(parsed.ratio);
    }
    const next = new URLSearchParams(searchParams?.toString() ?? "");
    next.delete("focus_artboard");
    next.delete("focus_phase");
    const qs = next.toString();
    router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false });
  }, [searchParams, projectId, router, pathname]);
```

- [ ] **Step 4: Slot in the top bar**

In the top bar's right cluster, make the slot the first child of `<div className="pointer-events-auto ml-auto flex items-center gap-3">`:

```tsx
          {clientLane && (
            <KvClientApprovalSlot
              fileId={fileId}
              fileName={shareFile?.name ?? "Key visual"}
              brandId={shareFile?.brand_id ?? null}
              surface="motion"
              formOpen={requestFormOpen}
              onFormOpenChange={setRequestFormOpen}
              onJump={handleApprovalJump}
            />
          )}
```

- [ ] **Step 5: Verdict on each tile**

In the `tileOverlays.map((d) => { const tileReady = readyStateForTile(d.tile); return ( <KvMotionTileStage …` element, add the prop:

```tsx
                verdict={verdictChip(
                  verdicts.get(motionSubjectKey(projectId, d.tile.key)),
                  // A re-export appends a row: the newest one is what the
                  // tile shows now. Unknown (no export yet) never hides.
                  { versionId: tileReady.latestExport?.id ?? null }
                )}
```

- [ ] **Step 6: Gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && F=(src/components/studio/kv-generator/motion/KvMotionEditor.tsx) && bunx prettier --write "${F[@]}" && npx eslint "${F[@]}" && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "KvMotionEditor" ; npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
```

Expected: no `KvMotionEditor` line; total at the Task 0 baseline.

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add src/components/studio/kv-generator/motion/KvMotionEditor.tsx && /usr/bin/git commit -F - <<'EOF'
feat(web): Motion editor — client slot, verdicts on tiles, jumps across editors

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 13: Gates, manual smoke, tri-mode, Lark taxonomy, track file

**Files:**
- Modify: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:** none.

- [ ] **Step 1: Type and lint gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && npx tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS" && BASE=$(/usr/bin/git log --format=%H --grep="track KV approval requests Part B" -1)~1 && F=($(/usr/bin/git diff --name-only "$BASE"..HEAD -- 'src/*.ts' 'src/*.tsx')) && npx eslint "${F[@]}"
```

Expected: the Task 0 number; eslint clean.

- [ ] **Step 2: §11.3 review greps**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && BASE=$(/usr/bin/git log --format=%H --grep="track KV approval requests Part B" -1)~1 && /usr/bin/git diff "$BASE"..HEAD -- src | /usr/bin/grep -E "^\+" | /usr/bin/grep -nE -- "-\[[0-9]+px\]|text-white|text-gray-|rgba\(26,26,26" ; for f in $(/usr/bin/git diff --name-only "$BASE"..HEAD -- 'src/*.tsx'); do if /usr/bin/grep -q 'from "@/components/frndos"' "$f" && /usr/bin/grep -q 'from "@/components/frndos/v2"' "$f"; then echo "MIX: $f"; fi; done
```

Expected: no added line with an arbitrary px value, `text-white`, `text-gray-*` or the old dark hex; no `MIX:` line except `motion/KvMotionEditor.tsx`, which mixed v1 (`BaseModal`, `Input`) and v2 (`Button`, `Popover`) before this branch — record that it is pre-existing and was not widened (it gained no v1/v2 import).

- [ ] **Step 3 (test): Every Part B test file, one per invocation**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/client-lane/canvasApproval.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvApprovalStatusList.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvClientApprovalSlot.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/client-lane/agency/KvReadyForClientTray.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvArtboardVerdictChip.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/useArtboardJump.test.tsx
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/lib/studio/kv/readySetFrame.test.ts
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && bun test src/components/studio/kv-generator/KvSharePanel.test.tsx
```

Expected: all pass; KvSharePanel at its Task 0 count. Check sizes: `ls -l` each new test file — every one < 45 KB.

- [ ] **Step 4: Manual smoke (Daffa, dev server, `show-client-lane` on)**

On a KV file with boards, Resize tiles and a Motion export:
1. Mark two artboards ready → the tray appears above the bottom nav with two thumbnails and "2 ready for client"; the top bar shows **Ready for client 2**.
2. Hover **Ready for client** → frames around both; pan both off screen and hover again → one "Off screen" pointer at the edge, pointing at them.
3. Press `–` → tray gone; unmark one → still gone; mark a third → back.
4. Open the comment dock (or dock the chat) → the slot becomes an icon with a badge; hover shows the tooltip.
5. Click **Request approval** on the tray → the form drops down under the slot, approvers from the last request, message "2 artboards ready: Craft 1 · Resize 1"; toggle a phase pill → the message follows; type → it stops following. Open **Decide by** and pick a date → the form stays open. Send.
6. The slot becomes "Waiting on Dina · 0/2"; each marked artboard shows **Waiting**; mark a third → `+1 ready` beside the chip.
7. Decide on the client page (Approve one with a pin, New version on the other) → after a refetch: **Approved with fixes**, **New version asked · n pins**; chip "Changes · 1/2".
8. Click the chip → popover; click the Resize row while on Concept → switches to Craft, centres and selects the tile, opens its pins in the dock. Click a Motion row → the Motion editor opens with that size focused; its top bar has the same chip, its tile shows its verdict; click a board row there → back to the KV editor on that board.
9. Iterate an approved board (new Craft version) → its **Approved** chip disappears. Regenerate an approved Resize tile → same. If the Resize chip never shows "Approved" even before regenerating, the snapshot `thumbnail_url` and the tile's `imageUrl` differ in URL form — report it (spec gap 3), do not patch around it.
10. Withdraw from the popover (••• → Withdraw → confirm) → the popover stays open through the confirm; chips go away.
11. Tri-mode: switch Midnight → Aurora → Daylight (profile menu → Miscellaneous → Theme) and re-check the tray, the slot (button, badge, chip, `+n ready`), both popovers, the verdict and ready chips on boards / tiles / motion tiles, and the frame + pointer. Nothing dark-on-dark or white-on-white; the badge reads in all three.

- [ ] **Step 5: Lark taxonomy rows (hand to Daffa)**

Add to the canonical taxonomy doc (`https://fcn.sg.larksuite.com/wiki/DMbKwqbzQiWrXSkha5zl1wFvgod`), domain `client_lane`, owner web:

| Event | Fires when | Properties |
|---|---|---|
| `client_lane.ready_tray_shown` | The Ready-for-client tray appears for a set of ready artboards not shown before this session (once per set, per file) | `ready_total` |
| `client_lane.ready_tray_tucked` | The tray is put away — its `–`, or the next press on the canvas | `ready_total`, `method` (`button` \| `canvas`) |
| `client_lane.status_chip_opened` | The top-bar approval status chip opens its popover | `surface` (`canvas` \| `motion`), `request_status`, `request_count`, `ready_total` |
| `client_lane.status_row_jumped` | An artboard row in the status popover takes the canvas to it | `surface`, `phase`, `status`, `replaced` |
| `client_lane.approval_request_form_opened` (existing row) | add `source` values `tray` and `top_bar` (Part A shipped `share_dialog`) | `source`, `ready_total` |

- [ ] **Step 6: Track file**

In `docs/tracks/client-lane-multi-item.track.md`: tick every Part B checklist item, and append to `## Session Log`:

```markdown
### 2026-10-01 — daffa (plan executor, Part B)
- Implemented Part B (spec §6.1): tray, top-bar slot (button → chip + popover, form drop-down), verdict chips on boards / resize tiles / motion tiles, hover frame + edge pointer, artboard jumps across editors, analytics.
- New v2: FloatingActionBar, CountBadge (stories + skill rows).
- Gates: tsc <n> (baseline <n>), eslint clean, Part B tests <results>, manual smoke <result>, tri-mode <result>.
- Open: spec gaps 1–4 in the plan (brand-level approver prefill, resize version identity, motion pins, transform-panel compact).
```

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-lane-multi-item && /usr/bin/git add docs/tracks/client-lane-multi-item.track.md && /usr/bin/git commit -F - <<'EOF'
docs(web): track KV approval requests Part B — gates and verification

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Rulings (decisions this plan makes where the spec is silent or does not fit the code)

1. **Withdrawn requests don't count for the slot.** A file whose every request was withdrawn shows **Ready for client**, not a chip; the newest *withdrawn* approval of an artboard gives it no verdict (an older answer is not resurrected). — A withdrawn request asked nothing of anyone; showing "Withdrawn" in the top bar would hide the next action.
2. **"Approved" disappears when the artwork changes; "Waiting" and "New version asked" don't.** — The former is a statement about pixels, the latter about the conversation; the agency iterating after "New version asked" is exactly when that chip is useful.
3. **Tuck = subset rule.** Unmarking never re-shows the tray; a new key or a new version does. — The spec's "keyed by the sorted set … a new mark shows the tray again" read literally would also re-show on every unmark, which is noise.
4. **Verdicts via context, not props.** — Four pass-through components for read-only display data.
5. **Approver prefill comes from the file's last request.** — There is no brand-level request list and Part B adds no api.
6. **Parsing artboard keys only to route.** — The contract says "compare, never parse"; a jump needs to know board vs tile vs clip and the motion project. Nothing is displayed from a parsed key.
7. **Motion editor: slot + verdicts, no tray, no hover frame, no pins.** — No bottom nav, tiles always on screen, no comments dock.
8. **The ready chip keeps its dark pill, and the verdict chip copies it.** — Daffa asked (2026-10-01) that the chips look exactly like the existing ready chip; a deliberate exception to §11's no-dark-hex rule for this canvas chrome, which is dark-only.

## Self-review

**Spec §6.1 coverage**

| Spec line | Task |
|---|---|
| Data: preview + list hooks; invalidated by mark/unmark settle, send/withdraw/resend, dialog closing | Part A hooks; Task 3 (mark/unmark, dialog close); Part A mutations already invalidate on send/withdraw |
| Tray: placement above `KvCanvasBottomNav`, `BOTTOM_TOOLBAR_SAFE_PX`, glass styling | Tasks 2, 7, 11 |
| Tray contents: ≤ 5 thumbnails + `+n`, `{n} ready for client`, Request approval, `–` | Task 7 |
| When it shows / tucking (`–` or canvas press, no timer) / sessionStorage per file by set | Task 7 (+ `data-kv-canvas-surface` in Task 11) |
| Top-bar slot left of the avatars; also in `KvMotionEditor` | Tasks 6, 11, 12 |
| No request + `preview.total > 0` → white **Ready for client ⑥**; compact = 32px icon + badge; compact also when chat dock narrows | Tasks 2, 6, 11 (transform panel: ruled out, spec gap 4) |
| Hover → frame around the set, or edge pointer off screen | Tasks 10, 11 |
| Any request → status chip; open wins; else last result; `+n ready` | Tasks 1, 6 |
| Click → the same request form drops down under the slot, prefilled approvers + default message | Tasks 3, 6 |
| Chip → popover, every request open-first, artboard rows (verdict, who, when, pins), verbs on the open one | Tasks 4, 5 |
| Row → move canvas (switch mode), select, open pins in the dock | Tasks 9, 11 (motion: Task 12) |
| Verdict chips: boards (`readyChipAt`), motion tiles, resize tiles; five states; status colours; one source | Tasks 1, 8 |
| Analytics: tray shown/tucked, chip opened, row jumped, form opened{source} | Tasks 1, 6, 7, 5; Lark rows Task 13 |
| §11 components first, tokens, tri-mode | Global Constraints; Tasks 2, 6–8, 10; review greps + tri-mode smoke Task 13 |

**Placeholder scan:** no TBD / "add handling" / "similar to Task N"; every code step carries its code. Two steps name a fallback the executor may need (`Button` default import in stories; `onToggleReadyToShare?.(row)` if tsc narrows badly) — both are concrete.

**Type consistency:** `slotStateOf`/`SlotState`, `artboardVerdicts`/`ArtboardVerdict`, `verdictChip`/`VerdictChipView`/`CurrentArtboardVersion`, `planArtboardJump`/`ArtboardJumpTarget`/`ArtboardJumpPlan`, `artboardHref`, `focusParamOf`, `boardSubjectKey`, `resizeSubjectKey`, `motionSubjectKey`, `TONE_DOT`, `ApprovalSurface`, `KvClientApprovalSlotProps`, `ArtboardJumpDeps` are spelled identically in Tasks 1, 5–12.

## Spec gaps (for Daffa / Jeff)

1. **"Approvers from the last request on this brand"** — no brand-level request endpoint exists; Part B uses the file's last request. A brand-wide prefill needs `GET v1/approval-requests?brand_id=…` (or a "last approvers" field).
2. **Resize version identity.** The contract's resize `version_id` is the row id, which a regenerate keeps; web can only tell the regenerated tile apart by comparing the snapshot `thumbnail_url` with the tile's `imageUrl`, and a layer-composed tile (`thumbnail_url = null`) can't be told apart at all. The api could expose the tile's `current_version_id` (already on `KvResizeExport.currentVersionId`) on each approval.
3. **Motion has no Comments dock**, so "open its pins" cannot apply to motion rows; the jump only focuses the size.
4. **"Compact when the transform panel narrows the bar"** — the panel never reaches the bar (bottom-anchored, max-height `100vh − 200px`); only the comment dock and a docked chat narrow it.
5. Spec is silent on **withdrawn requests** in the slot and on **stale "Approved"** verdicts — see Rulings 1–2.

## Components that did not fit (and what replaced them)

- v1 `FloatingSelectionBar` → new v2 **`FloatingActionBar`** (it is `fixed bottom-[70px]`, scoped to `[data-shell-content-card]`, viewport-centred outside the SidebarShell; the KV canvas is outside the shell and narrowed by docks).
- v2 `DropSuggestionBar` → not used (focus-on-mount + global Escape would interrupt typing every time something is marked).
- No badge in v1 or v2 → new v2 **`CountBadge`**.
- Canvas verdict chip → canvas chrome, not a frndOS component (as §11.2 says), in the ready chip's dark-pill recipe with tone dots from `statusTone.ts`.
