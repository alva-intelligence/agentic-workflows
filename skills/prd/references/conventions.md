## PRD Conventions

### Main PRD

- Location: `frnd/docs/prd/<feature-slug>.md`
- Created during `prd_creation` phase from user's Lark notes or verbal description

#### Required Frontmatter

```yaml
---
title: <Feature Name>
slug: <feature-slug>
author: <who wrote this>
created: <YYYY-MM-DD>
status: draft | review | approved
services: [api, web, ai-service, data-service]  # which services are touched
---
```

#### Required Sections

1. **Overview** — What this feature does, who it's for
2. **User Stories** — As a [role], I want [action], so that [benefit]
3. **Requirements** — Functional requirements, numbered (FR-1, FR-2, ...)
4. **Non-Functional Requirements** — Performance, security, scalability
5. **Service Breakdown** — What each service needs to do (this drives PRD splitting)
6. **UI/UX** — Key screens, interactions, mock-data notes (only when `implementation_strategy === "wireframe_then_implementation"`)
7. **Data Model** — New tables, columns, relationships
8. **API Endpoints** — New or modified endpoints
9. **Acceptance Criteria** — How to verify the feature works
10. **Open Questions** — Unresolved decisions

### Service PRD

- Location: `<service>/docs/prd/<feature-slug>.md`
- Created during `prd_splitting` phase by splitting the main PRD

#### Required Frontmatter

```yaml
---
title: <Feature Name> — <Service Name>
slug: <feature-slug>
parent_prd: docs/prd/<feature-slug>.md
service: <api|web|ai-service|data-service>
created: <YYYY-MM-DD>
status: draft | in_progress | completed
---
```

#### Required Sections

1. **Scope** — What THIS service needs to implement (subset of main PRD)
2. **Dependencies** — What other services this depends on
3. **Implementation Tasks** — Numbered task list (TASK-1, TASK-2, ...)
4. **API Contract** — Endpoints this service exposes or consumes
5. **Data Changes** — Migrations, schema changes for this service
6. **Verification** — Manual verification steps (how to test by hand). Automated tests are opt-in — only include an automated-test subsection if the user explicitly asked for tests (see `.agentic-workflows/fragments/testing-policy.md`).

### Naming

- Main PRD: `frnd/docs/prd/brand-health-dashboard.md`
- Service PRDs: `api/docs/prd/brand-health-dashboard.md`, `web/docs/prd/brand-health-dashboard.md`, etc.
- Use kebab-case for slugs
