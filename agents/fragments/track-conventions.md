## Track File Conventions

### Location

Track files live at: `<service>/docs/tracks/<feature-slug>.track.md`

### Required Frontmatter

```yaml
---
prd: <feature-slug>
parent_prd: docs/prd/<feature-slug>.md
service: <api|web|ai-service|data-service>
branch: feature/<feature-slug>
pr_url: <GitHub PR URL or null>
status: in_progress | completed
---
```

### Required Sections

#### Status Table

| Item | Status |
|------|--------|
| Wireframe | draft / approved |
| PRD | draft / approved |
| Service PRD | draft / in_progress / completed |
| Implementation | not_started / in_progress / completed |
| PR | not_submitted / submitted / merged |

#### Task Checklist

Derived from the service PRD's Implementation Tasks:

- [ ] TASK-1: Description
- [ ] TASK-2: Description
- [x] TASK-3: Description (completed)

#### Session Log

Append-only log of work done:

```
### 2026-03-18 — fahrizky (frndos-implement)
- Implemented TASK-1: Created API endpoint for brand health metrics
- Implemented TASK-2: Added database migration for brand_metrics table
- Next: TASK-3 (frontend component)

### 2026-03-19 — daffa (frndos-implement)
- Implemented TASK-3: Created BrandHealthDashboard component
- All tasks complete, ready for PR
```

### Rules

- Track files are the audit trail — never delete session log entries
- Update the task checklist as work progresses
- Update the status table when phases change
- The `pr_url` field is set when the PR is created
- Mark `status: completed` only when the PR is merged
