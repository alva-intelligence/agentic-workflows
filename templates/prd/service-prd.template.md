---
title: {{FEATURE_TITLE}} — {{SERVICE_NAME}}
slug: {{FEATURE_SLUG}}
parent_prd: docs/prd/{{FEATURE_SLUG}}.md
service: {{SERVICE_ID}}
created: {{DATE}}
status: draft
---

# {{FEATURE_TITLE}} — {{SERVICE_NAME}} Service PRD

## Scope

This document covers the {{SERVICE_NAME}} implementation for the {{FEATURE_TITLE}} feature.

{{SCOPE_DESCRIPTION}}

## Dependencies

### Depends On
- {{DEPENDENCY}}

### Depended By
- {{DEPENDENT}}

## Plan

_Approach before implementation. Each task also carries a plan and verification plan in the track._

- **Approach:** {{APPROACH}}
- **Files/areas touched:** {{TOUCHED_AREAS}}
- **Risks:** {{RISKS}}
- **Open technical decisions:** {{TECHNICAL_DECISIONS}}

## Implementation Tasks

- [ ] **TASK-1:** {{TASK_DESCRIPTION}}
- [ ] **TASK-2:** {{TASK_DESCRIPTION}}

## API Contract

### Endpoints Exposed

| Method | Endpoint | Request Body | Response | Auth |
|--------|----------|-------------|----------|------|
| {{METHOD}} | {{ENDPOINT}} | {{REQUEST}} | {{RESPONSE}} | {{AUTH}} |

### Endpoints Consumed

| Service | Method | Endpoint | Purpose |
|---------|--------|----------|---------|
| {{SERVICE}} | {{METHOD}} | {{ENDPOINT}} | {{PURPOSE}} |

## Data Changes

### New Migrations

{{MIGRATIONS}}

### Schema Changes

{{SCHEMA_CHANGES}}

### Rollback / Recovery

{{ROLLBACK}}

## Verification

_Existing targeted tests, lint, type checks, manual checks, and minimal runnable regression checks
are the default evidence. Do not add test dependencies or scaffold a new suite.
Never describe this section as formal verification._

- **Risk level:** low / medium / high
- **Existing checks to run:** {{CHECKS}}
- **Minimal regression check:** {{REGRESSION}}
- **Manual verification:** {{MANUAL_STEPS}}
- **Expected evidence:** {{EVIDENCE}}

## Delivery

_Delivery mode is authorized per task in workflow state and the track. This section records
constraints only._

- **Live estate:** {{LIVE_ESTATE}} (yes for `data-pipeline`)
- **Delivery constraints:** {{DELIVERY_CONSTRAINTS}}
- **Manual local test steps (if `local_test`):** {{LOCAL_TEST_STEPS}}

## Open Questions

- [ ] Q-1: {{QUESTION}}
