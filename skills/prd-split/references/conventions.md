## PRD Conventions

### Main PRD

- Location: `docs/prd/<feature-slug>.md`
- Created during automatic preparation after scope approval. The PRD is a preparation artifact;
  it is not a human checkpoint and does not need a draft-review loop.
- Feature path only. Bugs/improvements never get a comprehensive PRD.

#### Required Frontmatter

```yaml
---
title: <Feature Name>
slug: <feature-slug>
author: <who wrote this>
created: <YYYY-MM-DD>
status: draft | review | approved
services: [api, web, ai-service, data-service, data-pipeline]  # services touched
---
```

`status` records document maturity, not workflow authority. An automatically written PRD starts as
`draft`; nobody needs to approve the document before preparation continues.

#### Required Sections

1. **Overview** — What this feature does, who it's for.
2. **Brainstorming Outcome** — Approved scope summary, decisions from `decisions[]`, and the
   questions/answers that were actually asked.
3. **Decisions & Assumptions** — Every assumption made while authoring, with rationale.
4. **User Stories** — As a [role], I want [action], so that [benefit].
5. **Requirements** — Functional requirements (FR-1, FR-2, ...) and non-functional requirements
   (NFR-1, ...).
6. **Service Breakdown** — What each service needs to do; drives `prd_splitting`.
7. **UI/UX** — Key screens and interactions when web work is in scope.
8. **Data Model** — New tables, columns, relationships.
9. **API Endpoints** — New or modified endpoints.
10. **Planning & Verification** — Risk-scaled implementation and verification approach. Reference
    the shared contract in `.agents/skills/workflow/references/track-conventions.md`; do not restate the
    full delivery/merge policy here.
11. **Delivery & Rollout** — Constraints, rollout notes, and whether the service is a live estate.
    Delivery authorization itself is per-task and lives in workflow state/track, not in the PRD.
12. **Acceptance Criteria** — Observable outcomes that prove the scope is met.
13. **Open Questions** — Truly unresolved decisions, if any.

#### Rules

- Resolve facts from code, existing artifacts, and web evidence before asking. Record assumptions
  rather than interviewing the user for the same decision twice.
- The PRD records scope and constraints. It never grants `scope_approved`,
  `implementation_approved`, `delivery`, or `live_merge_approved` by existing.
- Keep the plan/verification contract aligned with the service PRDs and tracks. Evidence is a
  recorded command/action plus observed result; never call checks or tests "formal verification" or
  "formal proof".
- No new test dependencies. Existing targeted tests/lint/checks are permitted and are the default
  evidence; new tests require an explicit user request for that task.

### Service PRD

- Location: `<service>/docs/prd/<feature-slug>.md`
- Created during `prd_splitting`, automatically for every service in the main PRD.

#### Required Frontmatter

```yaml
---
title: <Feature Name> — <Service Name>
slug: <feature-slug>
parent_prd: docs/prd/<feature-slug>.md
service: <api|web|ai-service|data-service|data-pipeline|desktop>
created: <YYYY-MM-DD>
status: draft | in_progress | completed
---
```

#### Required Sections

1. **Scope** — What THIS service implements (subset of the main PRD).
2. **Dependencies** — What other services this depends on, and what depends on it.
3. **Plan** — Approach, files/areas touched, risks, and open technical decisions.
4. **Implementation Tasks** — Numbered task list (TASK-1, TASK-2, ...). Each task carries its plan
   and verification plan in the track.
5. **API Contract** — Endpoints this service exposes or consumes.
6. **Data Changes** — Migrations, schema changes, and rollback considerations.
7. **Verification** — Risk-scaled verification plan and manual steps. Existing targeted automated
   checks are allowed and expected; new tests/dependencies require an explicit user request. Never
   describe this section as formal verification.
8. **Delivery** — Delivery constraints for this service, including whether merging is live (for
   example `data-pipeline`). The actual delivery mode is authorized per task in workflow state and
   the track.
9. **Open Questions** — Unresolved decisions, if any.

#### Rules

- Each service PRD maps to one track file at `<service>/docs/tracks/<feature-slug>.track.md`.
- Do not ask the user to approve each service PRD. Preparation continues to the implementation
  checkpoint.
- The branch is created locally during splitting and is not pushed before implementation approval.

### Naming

- Main PRD: `docs/prd/brand-health-dashboard.md`
- Service PRDs: `api/docs/prd/brand-health-dashboard.md`,
  `web/docs/prd/brand-health-dashboard.md`, etc.
- Tracks: `api/docs/tracks/brand-health-dashboard.track.md`, etc.
- Use kebab-case for slugs.
