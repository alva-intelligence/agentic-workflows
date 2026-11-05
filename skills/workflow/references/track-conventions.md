## Track File Conventions

### Location

Track files live at: `<service>/docs/tracks/<feature-slug>.track.md`

### Required Frontmatter

```yaml
---
prd: <feature-slug>
parent_prd: docs/prd/<feature-slug>.md   # feature path only
service: <api|web|ai-service|data-service|data-pipeline|hocuspocus|desktop>
branch: <prefix>vc-<feature-slug>         # prefix = feature/ | fix/ | improvement/
pr_url: <GitHub PR URL or null>
status: in_progress | completed
execution_mode: main | subagents | null
delivery: local_test | open_pr | auto_merge | null
live_merge_approved: false
review_watch:
  status: not_started | watching | paused | done | expired
  deadline: <ISO 8601 or null>
  max_minutes: 30
  max_rounds: 3
  rounds_used: 0
  last_checked_sha: null
---
```

- `delivery` is user instruction only. It is not inferred from the branch, PRD, or PR, and it is
  not copied from another task. A verified explicit consent for **this same task** stays valid
  across resume; do not re-ask it. Default `null`.
- `live_merge_approved` is a separate user approval required before merging a live estate
  (`data-pipeline`). Default `false`.
- `review_watch` persists the bounded watch. Resume keeps the original `deadline` and
  `rounds_used`; only the user can grant a new budget.
- Old tracks without these fields are valid. Read absent fields as the defaults above; add the
  fields when the track is next updated. Do not rewrite history.

### Required Sections

#### Status Table

| Item | Status |
|------|--------|
| PRD | draft / approved / n/a (bug/improvement) |
| Service PRD | draft / in_progress / completed / n/a |
| Plan | missing / prepared |
| Implementation | not_started / in_progress / completed |
| Verification | not_started / in_progress / completed |
| Delivery | not_chosen / local_test (manual test pending) / open_pr / auto_merge |
| PR | not_submitted / submitted / merged / n/a |

#### Checkpoints

Record each human checkpoint with its authority source and date. A checkpoint is `n/a` only when
the work type does not have it (for example, no PRD checkpoint for bugs).

| Checkpoint | State | Approved by / source | Date | Notes |
|---|---|---|---|---|
| Scope | approved / pending | `<user wording or automation>` | | |
| Implementation | approved / pending | `<user wording or automation>` | | |
| Delivery | local_test / open_pr / auto_merge / not_chosen | `<user wording>` | | |
| Live merge | approved / not_required / pending | `<user wording>` | | data-pipeline only |

#### Execution & Delivery

- Resolved `execution_mode` and why (feature/improvement default subagents; bug default main;
  trivial/coupled stays main; complex bug may use subagents; user override).
- Subagent/task split when `subagents`.
- Delivery constraints: live estate, branch protection, review requirements.
- The full auto-merge gate lives in `skills/workflow/SKILL.md`; reference it, do not duplicate it.

#### Tasks

One block per task, with plan, verification plan, risk, and evidence. Keep the checklist.

- [ ] **TASK-1:** Description
  - **Plan:** approach, files/areas, dependencies, risks.
  - **Verification plan:** risk level; exact checks; expected evidence; manual steps.
  - **Evidence:** command/action → observed result; head SHA when relevant.
  - **Status:** pending / in_progress / done / blocked.

Risk levels: **low** (isolated/small surface), **medium** (normal endpoint/component/flow),
**high** (auth, data migrations, live estate, cross-service contract).

#### Verification Log

Append-only record of checks actually run:

```
### 2026-03-18 — <check name>
- Command/action: <exact command or manual step>
- Result: <pass/fail + observed output summary>
- Head SHA: <sha or n/a>
- Scope: <what this proves; what it does not>
```

Never say "formal verification" or "formal proof". Say what was run and observed. Every push
invalidates head-specific proof; record the new SHA when checks are re-run.

#### Review Watch

Mirror the frontmatter state here with progress notes:

```
- Started: <ISO>
- Deadline: <ISO> (max 30 minutes by default)
- Rounds: <used>/<max 3>
- Last checked SHA: <sha>
- Next action: <what to do on resume>
- Status: watching | paused | done | expired
```

On timeout, exhausted rounds, or session end, mark `paused`/`expired` with the exact next action.
Never claim background monitoring continues. Resume from this section without resetting the
deadline or round count.

#### Session Log

Append-only log of work done:

```
### 2026-03-18 — fahrizky (subagent/web)
- Implemented TASK-1: Created API endpoint for brand health metrics
- Implemented TASK-2: Added database migration for brand_metrics table
- Evidence: `bun test src/metrics` → 12 passed; manual dashboard check at localhost:3000/health
- Next: TASK-3 (frontend component)

### 2026-03-19 — daffa (main)
- Implemented TASK-3: Created BrandHealthDashboard component
- Final review: whole diff read; no must-fix items
- Delivery: local_test — manual test pending; server left on localhost:3000 for the user
```

### Rules

- Tracks are the audit trail — never delete session log entries or verification records.
- Update the task checklist as work progresses, not at the end.
- Plans and verification plans are written **before** implementation of each task and scaled to
  risk. Evidence is recorded after.
- The status table and checkpoints mirror authoritative workflow state; they do not create
  authority. A `delivery` value in a track only counts when the user instructed it for this task.
- `status: completed` means the final delivery is satisfied: the authorized PR merged, or the user explicitly closed the task. A `local_test` track stays `in_progress` while the manual test is pending — keep the branch and the requested server running, and do not mark completion or clean up. After the user reports the manual result they choose `open_pr` or `auto_merge`, and the normal phases continue. An `open_pr` track stays `in_progress` until a human merges.
- The `pr_url` field is set when the PR is created.
- Keep the plan/verification wording aligned with `skills/workflow/references/testing-policy.md`
  and `skills/workflow/SKILL.md`; do not restate the full merge checklist in every track.
