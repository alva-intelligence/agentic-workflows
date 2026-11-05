---
prd: {{FEATURE_SLUG}}
parent_prd: docs/prd/{{FEATURE_SLUG}}.md
service: {{SERVICE_ID}}
branch: {{BRANCH_PREFIX}}vc-{{FEATURE_SLUG}}
pr_url: null
status: in_progress
execution_mode: {{EXECUTION_MODE}}
delivery: null
live_merge_approved: false
review_watch:
  status: not_started
  deadline: null
  max_minutes: 30
  max_rounds: 3
  rounds_used: 0
  last_checked_sha: null
---

# {{FEATURE_TITLE}} — {{SERVICE_NAME}} Track

## Status

| Item | Status |
|------|--------|
| PRD | {{PRD_STATUS}} |
| Service PRD | draft |
| Plan | prepared |
| Implementation | not_started |
| Verification | not_started |
| Delivery | not_chosen |
| PR | not_submitted |

## Checkpoints

| Checkpoint | State | Approved by / source | Date | Notes |
|---|---|---|---|---|
| Scope | pending | | | |
| Implementation | pending | | | |
| Delivery | not_chosen | | | |
| Live merge | not_required | | | data-pipeline only |

## Phase Progress

| Phase | phase_status |
|-------|--------------|
| brainstorming | {{BRAINSTORMING_PHASE_STATUS}} |
| prd_creation | {{PRD_CREATION_PHASE_STATUS}} |
| prd_splitting | {{PRD_SPLITTING_PHASE_STATUS}} |
| implementation | {{IMPLEMENTATION_PHASE_STATUS}} |
| pr_submission | {{PR_SUBMISSION_PHASE_STATUS}} |
| pr_review | {{PR_REVIEW_PHASE_STATUS}} |
| completion | {{COMPLETION_PHASE_STATUS}} |

## Execution & Delivery

- **Execution mode:** {{EXECUTION_MODE}} — <why this mode>.
- **Task split:** <subagent/task ownership, or "main implements directly">.
- **Delivery constraints:** <branch protection, live estate, review requirements>.
- Full auto-merge gate: `.agents/skills/workflow/SKILL.md` (not duplicated here).

## Tasks

_Derived from the service PRD implementation tasks. Plan and verification plan are written before
each task starts; evidence is recorded after._

- [ ] **TASK-1:** {{TASK_DESCRIPTION}}
  - **Plan:** <approach, files/areas, dependencies, risks>
  - **Verification plan:** <risk level; exact checks; expected evidence; manual steps>
  - **Evidence:** <command/action → observed result; head SHA when relevant>
  - **Status:** pending

## Verification Log

_Append-only. Record exact commands/actions and observed results. Never describe checks as formal
verification or formal proof._

### {{DATE}} — initial preparation
- Command/action: <none yet>
- Result: plan prepared; implementation not started
- Head SHA: n/a

## Review Watch

- Started: n/a
- Deadline: n/a (default max 30 minutes)
- Rounds: 0/3
- Last checked SHA: n/a
- Next action: none until a PR is opened
- Status: not_started

## Session Log

### {{DATE}} — {{WORKER}} ({{AGENT}})
- Prepared track for {{FEATURE_TITLE}}
