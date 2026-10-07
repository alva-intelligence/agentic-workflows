# Client "Insights only" access — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support the client access level `insights_only` in the portal and agency UI:
- the portal shows only Insights, with an empty state when nothing is open;
- Invite / Clients offer the level;
- the agency is told when naming such a client upgraded them.

**Architecture:**
- `ClientAccessLevel` gains `"insights_only"`. Every `Record<ClientAccessLevel, …>` map then fails to type-check until it gets the new key, which is the checklist.
- **Portal:** the server page redirects `insights_only` lanes to `/insights`. `PortalNav` drops Approvals for them. The insights layout stops bouncing them back to Approvals when no tab is open and renders an empty state instead.
- **Agency:** a 4th chip, copy, and a toast driven by the api's new `access_upgraded` field.

**Tech Stack:** Next.js 16, React 19, TypeScript, TanStack Query v5, Tailwind, frndOS v2 (Base UI) components, bun test.

**Spec:** `docs/superpowers/specs/2026-10-07-client-insights-only-access-design.md` (workspace repo). The api contract comes from `docs/superpowers/plans/2026-10-07-client-insights-only-api.md`, built in parallel.

## Global Constraints

- **Repo and branch:**
  - Work in `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-portal`.
  - First run `git fetch origin develop && git switch -c feature/daffa/vc-client-insights-only origin/develop`.
  - If `bun.lock` differs from the old branch, run `bun install`.
- **Git:**
  - Commits: `feat(web): …` / `test(web): …`, each ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - NEVER push, no PR, never stash, never force.
- **A dev server runs from this directory:**
  - do NOT run `next build` / `bun run build`;
  - do not delete `.next`.
- **Tests:**
  - `bun test <explicit file>` only, never a directory;
  - RTL uses `within(document.body)`, not `screen`;
  - keep each test file under ~45KB.
- **Type check:**
  - `bunx tsc --noEmit -p .`, filtered to the files you touch;
  - the baseline is 890 errors, with only 3 pre-existing in OverviewHomeContent.tsx, KvGeneratorLayout.tsx and KvMotionEditor.tsx; add none.
- **Lint:** `bunx eslint <touched files>` must be clean.
- **UI:**
  - frndOS v2 first, v1 fallback, never mix v1 and v2 in one file;
  - design tokens only (no new hex, no `text-white`, no `text-[Npx]`);
  - must work in Midnight, Aurora and Daylight and at phone width.
  - Read `.agents/skills/frndos-components-v2/SKILL.md` and `.agents/skills/frndos-analytics-events` first.
- **Exact copy:**
  - value `insights_only`;
  - label and chip: "Insights only";
  - hint: "Sees only the Insights tabs you open to clients — no approvals.";
  - empty state: "{agency} hasn't shared any insights for {brand} yet.";
  - toast, one person: "{name}'s access changed to Own requests so they can approve.";
  - toast, several: "{n} clients' access changed to Own requests so they can approve.";
  - invite draft: "Hi {first} — this is where you'll see {brand}'s insights. No password: this email is your link."
- **Api contract (parallel work):**
  - request-create and round-create 201 bodies add `access_upgraded: Array<{email: string; name: string}>`. Treat a missing field as `[]`.
  - `me` brands and approver suggestions carry `access_level`, which may now be `"insights_only"`.
  - `GET …/approvals` answers 404 for that level; the web must never call it for such a lane.

## Review Focus

1. Redirect loop. The root page redirects `insights_only` → `/insights`, and today `insights/layout.tsx` redirects to the root when no tab is open. For `insights_only` the layout must render the empty state instead, never redirect. Test it.
2. Multi-brand client: `insights_only` on brand A and `own` on brand B. The brand switcher lands on A's Insights and on B's Approvals. `PortalNav` follows the CURRENT brand's level.
3. An `insights_only` client on a request-review page (`/s/{token}`) from an old link sees the read-only view; the existing view-only notice shows and the decision bar can't approve.
4. A missing `access_upgraded` (older api) must not crash or toast.
5. Invite with "Insights only" picked while no tab is open shows the non-blocking note with a link to `/brands/{id}/settings/insights-tabs`, and Send still works.

---

### Task 1: The level in shared rules and copy

**Files:**
- Modify: `src/lib/client-lane/portal/types.ts` (`ClientAccessLevel`, `CLIENT_ACCESS_LEVELS`)
- Modify: `src/lib/client-lane/portal/inbox.ts` (`ACCESS_LEVEL_LABEL`)
- Modify: `src/lib/client-lane/clients.ts` (`ACCESS_LEVEL_CHIP`, `accessLevelHint`, `inviteDraft`, a new `accessUpgradedToast`)
- Test: `src/lib/client-lane/clients.add.test.ts`, plus the inbox rules test that covers `ACCESS_LEVEL_LABEL` if one exists

**Interfaces:**
- Produces:
  - `type ClientAccessLevel = "own" | "all_approve" | "all_view" | "insights_only"`;
  - `CLIENT_ACCESS_LEVELS` includes it, last;
  - `ACCESS_LEVEL_LABEL.insights_only = "Insights only"`;
  - `ACCESS_LEVEL_CHIP.insights_only = "Insights only"`;
  - `accessLevelHint("insights_only", brand)` returns the hint above;
  - `inviteDraft(name, brandName, level?: ClientAccessLevel)` returns the insights draft for that level (default unchanged);
  - `export function accessUpgradedToast(upgraded: ReadonlyArray<{ email: string; name: string }>): string | null` returns null for `[]`, the one-person copy (using `name`, else `email`) for 1, and the `{n} clients'` copy for more;
  - `export function isInsightsOnly(level: ClientAccessLevel | null | undefined): boolean`.

- [ ] **Step 1: Failing tests.**

```ts
it("labels the insights-only level", () => {
  expect(ACCESS_LEVEL_CHIP.insights_only).toBe("Insights only");
  expect(accessLevelHint("insights_only", "frndGlow")).toBe(
    "Sees only the Insights tabs you open to clients — no approvals."
  );
  expect(inviteDraft("Dina Pratiwi", "frndGlow", "insights_only")).toBe(
    "Hi Dina — this is where you'll see frndGlow's insights. No password: this email is your link."
  );
  expect(inviteDraft("Dina Pratiwi", "frndGlow")).toContain("approvals");
});

it("words the access-upgrade toast", () => {
  expect(accessUpgradedToast([])).toBeNull();
  expect(accessUpgradedToast([{ email: "d@b.co", name: "Dina" }])).toBe(
    "Dina's access changed to Own requests so they can approve."
  );
  expect(accessUpgradedToast([{ email: "d@b.co", name: "" }])).toBe(
    "d@b.co's access changed to Own requests so they can approve."
  );
  expect(
    accessUpgradedToast([
      { email: "a@b.co", name: "A" },
      { email: "c@b.co", name: "C" },
    ])
  ).toBe("2 clients' access changed to Own requests so they can approve.");
});
```

- [ ] **Step 2:** Run `bun test src/lib/client-lane/clients.add.test.ts`; it FAILS.
- [ ] **Step 3: Implement.**
  - Widen the type and the arrays/maps, then add the functions. `accessLevelHint` gets the new `case`.
  - Run tsc filtered to `src/`: every `Record<ClientAccessLevel, …>` / exhaustive `switch` that now errors must get the new key or case. List each one in the commit message body.
- [ ] **Step 4:** Run the test file(s) and tsc; both PASS.
- [ ] **Step 5:** Commit `feat(web): insights_only access level in client-lane rules and copy`.

### Task 2: Portal shows only Insights

**Files:**
- Modify: `src/app/s/[token]/[brand]/page.tsx` (redirect)
- Modify: `src/app/s/[token]/[brand]/insights/layout.tsx` (no bounce; empty state)
- Modify: `src/components/client-lane/portal/PortalNav.tsx` (drop Approvals)
- Modify: whatever renders `PortalNav` with the current brand (grep `PortalNav`), to pass the level
- Create: `src/components/client-lane/portal/PortalInsightsEmpty.tsx`
- Test: `src/components/client-lane/portal/PortalNav.test.tsx` (create or extend), `src/components/client-lane/portal/PortalInsightsEmpty.test.tsx`

**Interfaces:**
- Consumes: `isInsightsOnly`, `portalInsightsHref(current)` (existing), `findPortalBrand` (existing).
- Produces:
  - `PortalNav` gains the prop `approvals?: boolean` (default `true`). When false, no Approvals item and no count; only Insights.
  - `<PortalInsightsEmpty agency={string} brand={string} />`.

- [ ] **Step 1: Failing tests.**
  - `PortalNav` with `approvals={false}` and an `insightsHref` → `within(document.body)` finds "Insights" and no "Approvals".
  - `PortalInsightsEmpty` renders "FCN hasn't shared any insights for frndGlow yet."
- [ ] **Step 2:** Run them; they FAIL.
- [ ] **Step 3: Implement.**
  - **Root page** (`page.tsx`): after `current` resolves, `if (isInsightsOnly(current.access_level)) redirect(portalInsightsHref(current));`. This sits outside any try/catch; keep the existing Promise.all.
  - **Insights layout:** when `isInsightsOnly(current.access_level)` and `!info || !hasClientInsights(info)`, render the portal shell (the same shell and top bar the layout uses for real tabs) with `<PortalInsightsEmpty agency={current.workspace…} brand={current.name…} />` in place of the tabs. Use the actual field names on the portal brand type. Keep today's redirect for the other levels. This is Review Focus 1.
  - **`PortalNav`:** honour `approvals={false}`. For an `insights_only` brand, Insights shows even when `insightsHref` would be null; pass `portalInsightsHref(current)`.
  - **Callers:** pass `approvals={!isInsightsOnly(current.access_level)}` and the forced insights href for `insights_only`. Grep `PortalNav` and `insightsHref` across `src/app/s` and `src/components/client-lane/portal`.
  - **`PortalInsightsEmpty`:** v2 typography and tokens, centred, one line of copy plus a quiet sub-line "Check back later — this page updates when they do." No CTA. It must look right in all three themes.
- [ ] **Step 4:** Run the tests, tsc (filtered) and eslint; all PASS. Add a test for Review Focus 2 if `PortalNav` takes the current brand: brand B (`own`) still shows Approvals.
- [ ] **Step 5:** Commit `feat(web): insights-only clients get an Insights-only portal`.

### Task 3: Agency — Invite, Clients tab, request toast

**Files:**
- Modify: `src/components/brands/settings/clients/AddClientFlow.tsx` (4th chip comes from `CLIENT_ACCESS_LEVELS`; draft by level; no-tabs note)
- Modify: `src/components/brands/settings/clients/ClientsTab.tsx` (the access select gets the new option, if it isn't already driven by `accessLevelOptions()`)
- Modify: the approver suggestion row (grep `approverSuggestions.ts` / `ApproverEmailsField`) to show an "Insights only" tag when `access_level === "insights_only"`
- Modify: `src/services/client-lane.ts` (`CreateApprovalResponse` gets `access_upgraded?`; the round-create response type too)
- Modify: the request form success handler (`src/components/client-lane/agency/RequestForm.tsx`, and the round send path if separate) → `showToast` with `accessUpgradedToast(...)` when non-null
- Modify: `src/lib/analytics/client-lane-events.ts` (the request-sent event gains `access_upgraded_count`) and `docs/tracks/client-portal.track.md` taxonomy rows
- Test: `src/components/brands/settings/clients/AddClientFlow.test.tsx`, `ApproverEmailsField.test.tsx`, and the RequestForm test (grep for it)

**Interfaces:**
- Consumes: `accessUpgradedToast`, `inviteDraft(…, level)`, `isInsightsOnly`, `ACCESS_LEVEL_CHIP`.
- Produces: `CreateApprovalResponse.access_upgraded?: Array<{ email: string; name: string }>`.

- [ ] **Step 1: Failing tests.**
  - **AddClientFlow:**
    - the "Can" segmented control has 4 items, including "Insights only";
    - picking it changes the hint and the drafted message to the insights copy (only while the user hasn't edited the message);
    - with no client-visible tabs (mock the source you choose, e.g. the brand's insights tab settings query), a note "No Insights tabs are open to clients yet." with a link to `/brands/{id}/settings/insights-tabs` shows, and Send still posts `access_level: "insights_only"` (Review Focus 5).
  - **Approver suggestions:** a suggestion with `access_level: "insights_only"` shows the "Insights only" tag.
  - **Request form:** a send whose response has `access_upgraded: [{email, name: "Dina"}]` calls the toast with the one-person copy. A response without the field shows no upgrade toast (Review Focus 4).
- [ ] **Step 2:** Run them; they FAIL.
- [ ] **Step 3: Implement.**
  - **Chips:** AddClientFlow already maps `CLIENT_ACCESS_LEVELS` → `ACCESS_LEVEL_CHIP`. Check the 4 chips fit the 680px dialog and wrap cleanly at phone width.
  - **Draft:** `messageValue = message ?? inviteDraft(fields.name, brandName, level)`.
  - **No-tabs note:** fetch the brand's Insights tab settings with the hook the Insights Tabs settings page already uses (grep `insights-tabs/page.tsx`), and treat "no row with `client_visible === true`" as no tabs.
  - **WhatsApp text:** already uses `messageValue`.
  - **Toast:** in the success handler, `const text = accessUpgradedToast(res.access_upgraded ?? []); if (text) showToast("Client access updated", text, "info")`. Use the toast tone the codebase uses for informational notices. The existing invalidation of brand-clients stays.
  - **Analytics:** add `access_upgraded_count: (res.access_upgraded ?? []).length` to the request-sent event wrapper and its test, plus a taxonomy row update.
- [ ] **Step 4:** Run the tests, tsc (filtered) and eslint; all PASS.
- [ ] **Step 5:** Commit `feat(web): insights-only in Invite, Clients and approver picker; upgrade toast`.

### Task 4: Wrap up

- [ ] Run every touched or covering test file individually with `bun test`, then tsc (filtered) and eslint.
- [ ] Append a session-log entry to `docs/tracks/client-portal.track.md` and commit `docs(web): track insights-only access`.
- [ ] Report: commits, test results, any copy or flow you changed and why, and what needs a browser check:
  - the portal redirect and nav;
  - the empty state in 3 themes and at phone width;
  - the 4-chip layout;
  - the toast.
