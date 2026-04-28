## {{PR_TITLE}}

### Summary

{{SUMMARY}}

### PRD

- [Main PRD]({{PRD_PATH}})
- [Service PRD]({{SERVICE_PRD_PATH}})

### Changes

{{CHANGES_LIST}}

### Track File

- [{{SERVICE}} track]({{TRACK_PATH}})

### Tasks Completed

{{TASK_CHECKLIST}}

### Self-review Summary

_Recorded by `frndos-pr` during `pr_submission`. Lists items checked plus any must-fix items found and how they were resolved._

{{SELF_REVIEW_SUMMARY}}

### Security Audit Summary

_Recorded by `frndos-pr` via the `security-reviewer` skill during `pr_submission`. Lists findings by severity. PRs only open when there are no unresolved high/critical findings._

{{SECURITY_AUDIT_SUMMARY}}

### Testing / Verification

{{TESTING_NOTES}}  <!-- Manual verification steps. Only include automated test notes if the user explicitly asked for tests (see testing-policy.md). -->

### Checklist

- [ ] Code follows service conventions (read service `AGENTS.md`)
- [ ] All tasks from service PRD are complete
- [ ] Track file updated with session log
- [ ] Self-review passed with no must-fix items remaining
- [ ] Security audit passed with no high/critical findings remaining
- [ ] Manual verification steps pass
- [ ] Automated tests pass (only applicable when the user explicitly requested tests — otherwise mark N/A)
- [ ] No `.env` or secrets committed
