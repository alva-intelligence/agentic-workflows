---
name: prd
description: Create a formal PRD from Lark notes or user description
---

# PRD Creator

Creates a formal Product Requirements Document from user input (Lark notes, verbal description, or Lark URL if Lark MCP is enabled).

## Commands

### `/prd create <slug>`
Create a new PRD for a feature.

**Steps:**

1. **Enter plan mode (MANDATORY).** Call your harness's plan mode before reading any file or forming conclusions:
   - Claude Code: `EnterPlanMode`
   - Cursor: plan mode
   - OpenCode: plan mode
   - Amp: no plan mode — announce an explicit "research phase" and stay read-only until Step 8.

2. Verify workflow state is in `prd_creation` phase (or `idle` — auto-start workflow).

3. Ask user for input source (use your ask tool — Claude Code: `AskUserQuestion`; Cursor: ask tool; OpenCode: question tool; Amp: ask as plain text and wait):
   - "Paste your Lark notes or feature description"
   - If Lark MCP is enabled: "Or provide a Lark doc URL"

4. If Lark URL provided and Lark MCP available, fetch content via MCP.

5. **Estimate PRD size. If > ~8000 tokens, propose split (MANDATORY).** Rough token count ≈ char_count / 3.5. If the source material is large enough that the drafted PRD would exceed ~8000 tokens, use your ask tool to propose splitting into priority-ordered sub-PRDs:
   - **P0** — must-have, first release
   - **P1** — important, follows P0
   - **P2** — nice-to-have, last

   Each sub-PRD becomes its own feature (own branch, own PRs). They share a parent feature slug: `<slug>-p0`, `<slug>-p1`, `<slug>-p2`. Record `features[<parent>].sub_features` on the parent entry and `features[<sub>].parent_feature` on each sub. User confirms split boundaries (which sections go in which sub-PRD) before creation. Each sub-PRD goes through the full workflow independently.

6. **Research current system state (MANDATORY — BEFORE DRAFTING).** Devs do this naturally, non-devs don't. Skipping produces PRDs that ignore existing behavior.
   - Read relevant service code (`api/app/`, `web/src/`, `ai-service/app/`, `data-service/app/`)
   - Read existing PRDs in `docs/prd/` — is there a related or overlapping feature?
   - Check recent commits on base branches (`develop` / `development`) in affected areas
   - Summarize findings to the user: "Here's what already exists that this PRD must reconcile with: [list]"

7. **Challenge assumptions (MANDATORY).** Identify at least 3 aspects of the user's description that are ambiguous, underspecified, or conflict with existing system behavior. Ask about each via your ask tool. Prefer multiple small questions over one mega-question.

8. **Relentless clarifying questions (MANDATORY).** Surface EVERY remaining ambiguity or assumption via your ask tool. Do NOT draft until ALL are answered. Also ask the baseline:
   - Which services does this touch?
   - Who are the primary users?
   - Technical constraints?
   - "Done" criteria?

9. Wait for user answers.

10. Exit plan mode. Read template from `.agentic-workflows/templates/prd/main-prd.template.md`.

11. Generate the PRD, filling in all sections. Include an "Existing System Reconciliation" subsection (findings from step 6) and an "Assumptions and Clarifications" subsection (decisions from steps 7-8).

12. Present the draft to user for review via the ask tool.

13. On approval, write to `docs/prd/<slug>.md`.

14. Update `.workflow-state.json` with `prd_path` (and `parent_feature` / `sub_features` if split).

### `/prd edit`
Edit the current feature's PRD.

**Steps:**
1. Read current PRD from path in `.workflow-state.json`
2. Ask user what to change (via your ask tool)
3. Present proposed changes
4. On approval, write changes
