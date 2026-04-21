---
name: prd-split
description: Split a main PRD into per-service PRDs
---

# PRD Splitter

Splits a main PRD into per-service PRDs based on the Service Breakdown section.

**Read `references/conventions.md` first** for the service-PRD frontmatter, required sections (including Verification rules), and the naming convention shared with main PRDs.

## Commands

### `/prd split`
Split the active feature's main PRD into service PRDs.

**Steps:**

1. **Enter plan mode (MANDATORY).** Call your harness's plan mode before reading any file or forming conclusions:
   - Claude Code: `EnterPlanMode`
   - Cursor: plan mode
   - OpenCode: plan mode
   - Amp: no plan mode — announce a "research phase" and stay read-only until Step 6.

2. Verify workflow state is in `prd_splitting` phase.

3. Read the main PRD from `.workflow-state.json` `prd_path`. Parse the "Service Breakdown" section.

4. **Research per-service codebases (MANDATORY).** For each service, read enough code to understand:
   - Existing patterns for similar endpoints/components/models
   - Integration points across services
   - Active work in `<service>/docs/tracks/` that might conflict

5. **Relentless clarifying questions (MANDATORY).** Before drafting any service PRD, surface EVERY ambiguity that would change how the split works, via your ask tool (Claude Code: `AskUserQuestion`; Cursor: ask tool; OpenCode: question tool; Amp: plain text, wait). Prefer multiple small questions over one mega-question. Do NOT proceed until answered.

6. Exit plan mode. For each service listed in the PRD frontmatter `services` field:
   a. Read the service PRD template
   b. Extract relevant requirements, API endpoints, data model changes for this service
   c. Generate implementation tasks (TASK-1, TASK-2, ...) from the requirements
   d. Present the draft service PRD to user
   e. Use your ask tool for approval — surface any remaining per-service ambiguities here
   f. On approval, write to `<service>/docs/prd/<slug>.md`
   g. Create track file at `<service>/docs/tracks/<slug>.track.md`

7. Update `.workflow-state.json` `service_prds` with paths.

8. Report summary: "Created service PRDs for: api, web, ai-service"

### `/prd split status`
Show which service PRDs have been created and their status.
