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

_Recorded by the orchestrator during `pr_submission`. Lists items checked plus any must-fix items found and how they were resolved._

{{SELF_REVIEW_SUMMARY}}

### Security Audit Summary

_Recorded by the orchestrator via the `security-reviewer` skill during `pr_submission`. Lists findings by severity. PRs only open when there are no unresolved high/critical findings._

{{SECURITY_AUDIT_SUMMARY}}

### Testing / Verification

{{TESTING_NOTES}}  <!-- Exact checks, observed results, manual steps, and unverified behavior. -->

### Delivery

- **Delivery choice:** {{DELIVERY}}  <!-- local_test | open_pr | auto_merge | null; explicit for this task; same-task resume may reuse recorded consent, never other-task/global consent -->
- **Authorization:** {{DELIVERY_AUTHORIZATION}}  <!-- who/when; scope or implementation approval is not merge consent -->
- **Live-estate merge approval:** {{LIVE_MERGE_APPROVAL}}  <!-- data-pipeline only; auto_merge alone is insufficient; production promotion stays human-only -->
- **Review watch:** {{REVIEW_WATCH}}  <!-- started/deadline, fix rounds used/max, latest head SHA, status -->
- **Merge evidence on latest head:** {{MERGE_EVIDENCE}}  <!-- required CI, configured expected review, paginated thread inventory; mechanics: skills/pr-feedback -->

### Checklist

- [ ] Code follows service conventions (read service `AGENTS.md`)
- [ ] All tasks from service PRD are complete
- [ ] Track file updated with session log
- [ ] Self-review passed with no must-fix items remaining
- [ ] Security audit passed with no high/critical findings remaining
- [ ] Delivery choice explicitly authorized for this task (same-task consent may survive resume; no other-task/global consent)
- [ ] If `auto_merge`: latest-head merge evidence recorded; every paginated thread addressed; branch protections not bypassed
- [ ] If `data-pipeline` touched: separate task-specific live-estate approval recorded; production promotion left to a human
- [ ] Manual verification steps pass
- [ ] Relevant automated checks pass; verification evidence and any untested behavior recorded
- [ ] No `.env` or secrets committed
