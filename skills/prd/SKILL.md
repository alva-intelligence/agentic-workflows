---
name: prd
description: Create the main PRD during automatic preparation after scope approval (feature path only)
---

# PRD Creator

Creates the main Product Requirements Document from the approved scope and available input (pasted
notes, verbal description, or a Lark doc URL read via the Lark CLI — read-only).

This is a **preparation step**, not a human checkpoint. For features it runs automatically after
scope approval, writes the PRD, and continues to `prd_splitting`. Do not ask the user to approve the
draft or each section. Bugs and improvements never enter this phase.

**Before drafting, read `references/conventions.md`** for the required frontmatter, required
sections, naming rules, and the main/service PRD split.

## Commands

### `/prd create <slug>`
Create the main PRD for a feature.

**Steps:**

0. **Guard.** Verify `features[active_feature].type === "feature"`. If it is `bug` or
   `improvement`, stop: those go straight to implementation preparation. Verify
   `features[active_feature].scope_approved === true` (absent = `false`). If scope is not
   approved, return to the `brainstorm` skill and run the scope checkpoint first. If the user
   explicitly skipped the main PRD, record that decision and continue to preparation without
   fabricating one — the service tracks are built from the approved scope summary.

1. **Activate phase.** Flip `features[active_feature].phase_status` to `"inprogress"` in
   `.workflow-state.json`.

2. **Read the approved inputs.** `brainstorming.summary`, `brainstorming.questions`,
   `brainstorming.decisions`, and `initial_request`. Also read the service state snapshots. These
   are the primary inputs; do not re-interview the user for facts already recorded.

3. **Gather only what is missing.** If the user supplied extra notes or a Lark URL, read them. If a
   Lark URL is provided and the Lark CLI is connected, fetch the document read-only. If a genuinely
   blocking product decision is still missing, fold it into **one** ask, record the answer, and
   continue. Do not run a challenge/relentless-clarifying loop.

4. **Research current system state (before drafting).** Read the relevant service code
   (`api/`, `web/`, `ai-service/`, `data-service/`, `data-pipeline/` as applicable), existing PRDs in
   `docs/prd/`, and recent commits in the affected areas. Reconcile the PRD with what already
   exists; record conflicts as decisions or open questions.

5. **Estimate size.** Rough token count ≈ character count / 3.5. If the drafted PRD would exceed
   ~8000 tokens, do not silently split. Treat the priority split as a scope decision and ask once
   (P0 must-have, P1 important, P2 nice-to-have). Each sub-PRD becomes its own feature with slug
   `<slug>-p0`, `<slug>-p1`, etc.; record `features[<parent>].sub_features` and
   `features[<sub>].parent_feature`. If the user already defined the split during scope, apply it
   without asking.

6. **Write the PRD directly** to `docs/prd/<slug>.md` using the template at
   `.agentic-workflows/templates/prd/main-prd.template.md` (installed path; in this source repo it
   is `templates/prd/main-prd.template.md`). Include:
   - `## Brainstorming Outcome` — the summary, the decisions from `decisions[]`, and the asked
     questions/answers.
   - `## Decisions & Assumptions` — every assumption made during authoring, with rationale.
   - `## Planning & Verification` — the risk-scaled plan/verification contract, referencing the
     track convention rather than restating the whole merge policy.
   - `## Delivery & Rollout` — delivery constraints only. Delivery authorization itself is
     per-task and lives in workflow state/track; do not record an auto-merge approval here.

   Do not present a draft for approval. The user will see the prepared artifact set at the
   implementation checkpoint.

7. **Update state and continue automatically.** Set `prd_path`, flip `phase_status` to
   `"completed"`, and move to `prd_splitting` without asking. No `/workflow next` ceremony.

### `/prd edit`
Edit the current feature's PRD on user request.

**Steps:**
1. Read the current PRD from the path in `.workflow-state.json`.
2. Apply the requested change. Ask only if the request is ambiguous or changes scope; a scope
   change may reopen the scope checkpoint.
3. Write the updated PRD and note the change in the relevant track's session log.
