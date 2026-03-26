---
name: workflow
description: Manage feature workflow state — status, transitions, context switching
---

# Workflow Manager

Manages the feature development workflow state machine.

## Commands

### `/workflow status`
Show the current workflow state for the active feature.

**Steps:**
1. Read `.workflow-state.json`
2. Display:
   - Active feature: `{active_feature}`
   - Current phase: `{phase}` ({phase_name})
   - Phase entered: `{phase_entered}`
   - Worker: `{worker}`
   - Wireframes: list with approval status
   - Branch: `{branch}` or "not created"
   - Service PRDs: list with status
   - PR: `{pr_url}` or "not submitted"

### `/workflow list`
Show ALL active features with their phases.

**Steps:**
1. Read `.workflow-state.json`
2. For each feature in `features{}`:
   - Show slug, phase, phase_entered, worker
   - Mark active feature with `→`

### `/workflow start <slug>`
Start a new feature workflow.

**Steps:**
1. **Check onboarding state first.** Read `.onboard-state.json`:
   - If file doesn't exist and no service directories → BLOCK: "Run `/onboard` first."
   - If `status` is `"in_progress"`, check critical steps:
     - `steps.env_files` must be `"completed"` (all services have real .env)
     - `steps.db_setup` must be `"completed"` (if API service is selected)
     - `steps.clone_repos` must be `"completed"`
     - `steps.install_deps` must be `"completed"`
   - If ANY critical step is missing → BLOCK and list what's needed:
     ```
     Cannot start workflow. Onboarding is incomplete:
       - api/.env is missing — contact arhen
       - Database not restored — contact arhen for dev dump
     Run `/onboard resume` to complete setup.
     ```
   - If `status` is `"completed"` → proceed
2. Read `.workflow-state.json` (create if doesn't exist)
3. Check that `<slug>` doesn't already exist in features
4. Create feature entry with phase: "prd_creation"
5. Set `active_feature` to `<slug>`
6. Set `phase_entered` to current timestamp
7. Ask user for worker name if not set
8. Save state
9. Inform user: "Feature `<slug>` started. Phase: prd_creation. Delegating to frndos-prd."

### `/workflow next`
Transition to the next phase (if gate conditions are met).

**Steps:**
1. Read `.workflow-state.json`
2. Get current phase for active feature
3. Look up gate conditions from `.agentic-workflows/workflow/gates.json`
4. Check EACH condition:
   - If all pass → transition to next phase, update `phase` and `phase_entered`
   - If any fail → report which conditions failed and what's needed
5. Save state
6. Inform user of new phase and which agent will handle it

### `/workflow switch <slug>`
Switch active feature context.

**Steps:**
1. Read `.workflow-state.json`
2. Verify `<slug>` exists in features
3. Save any pending state for current feature
4. Set `active_feature` to `<slug>`
5. Load target feature's phase context
6. If on a different git branch, inform user: "Feature `<slug>` is on branch `{branch}`. Switch with: `git checkout {branch}`"
7. Save state

### `/workflow list-all`
Discover ALL features across the team — not just local ones. Scans committed artifacts and git branches.

**Steps:**
1. Fetch latest from all remotes: `git fetch --all` in each service dir
2. Scan for features from multiple sources:
   - **PRDs:** `ls docs/prd/*.md` → extract slugs
   - **Feature branches:** `git branch -r | grep 'feature/vc-'` in each service → extract slugs
   - **Track files:** `find . -name '*.track.md'` across all services → extract slugs
   - **Wireframes:** `ls web/src/app/(dashboard)/wireframes/` → extract slugs
3. For each unique slug found, reconstruct the phase (same logic as resume):
   - PRD exists? Wireframe approved? Branch exists? Service PRDs? Track progress? PR?
4. Also check local `.workflow-state.json` for any features only tracked locally
5. Display a table:

```
All features (committed artifacts + local state):

  Slug                        Phase              Last Activity         Worker
  ─────────────────────────── ────────────────── ───────────────────── ──────────
→ brand-health-dashboard      implementation     2026-03-20 (track)    fahrizky
  user-analytics              pr_review          2026-03-18 (PR #42)   daffa
  kv-generator                prd_creation       2026-03-15 (PRD)      arhen

→ = active in your local .workflow-state.json
```

6. Show: "To pick up a feature: `/workflow resume <slug>`"

### `/workflow resume <slug>`
Resume a feature started by another team member.

**Steps:**
1. Fetch latest: `git fetch --all` in each service dir
2. Scan committed artifacts to reconstruct phase:
   - PRD exists at `docs/prd/<slug>.md`? → past prd_creation
   - Wireframe directory exists with approved metadata.json? → past wireframe_review
   - Feature branch `feature/vc-<slug>` exists? → past branch_creation
   - Service PRDs exist? → past prd_splitting
   - Track files show progress? → in implementation
   - PR URL in track file? → in pr_review
3. Read the latest session log from track files to show who last worked on it and what they did
4. Create/update feature entry in `.workflow-state.json` with reconstructed state
5. Set `active_feature` to `<slug>`
6. Ask user for their worker name if not already set
7. Inform user:
   - Reconstructed phase
   - Last session log entry (who did what)
   - What's left to do (remaining tasks from track file)
   - Which branch to checkout: `git checkout feature/vc-<slug>`

### `/workflow add-wireframe <wireframe-slug>`
Add a new wireframe to the current feature.

**Steps:**
1. Read `.workflow-state.json`
2. Verify active feature is in `wireframe` or `wireframe_review` phase
3. Add new wireframe entry with slug, empty path, current worker as owner, null approval
4. Save state
5. Inform user and delegate to frndos-wireframe

### `/workflow progress`
Show detailed progress for the active feature.

**Steps:**
1. Read `.workflow-state.json` and all related files
2. Show:
   - Phase progression timeline
   - Wireframe status for each wireframe
   - Service PRD status
   - Track file task completion percentage
   - Session log summary
