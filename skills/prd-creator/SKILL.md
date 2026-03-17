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
1. Verify workflow state is in `prd_creation` phase (or `idle` — auto-start workflow)
2. Ask user for input source:
   - "Paste your Lark notes or feature description"
   - If Lark MCP is enabled: "Or provide a Lark doc URL"
3. If Lark URL provided and Lark MCP available, fetch content via MCP
4. Analyze the input and ask clarifying questions:
   - Which services does this touch?
   - Any specific technical constraints?
   - Who are the primary users?
5. Wait for user answers
6. Read template from `.agentic-workflows/templates/prd/main-prd.template.md`
7. Generate the PRD, filling in all sections
8. Present the draft to user for review
9. On approval, write to `docs/prd/<slug>.md`
10. Update `.workflow-state.json` with prd_path

### `/prd edit`
Edit the current feature's PRD.

**Steps:**
1. Read current PRD from path in `.workflow-state.json`
2. Ask user what to change
3. Present proposed changes
4. On approval, write changes
