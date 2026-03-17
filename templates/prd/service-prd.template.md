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

## Testing

### Unit Tests
- {{TEST}}

### Integration Tests
- {{TEST}}

### Manual Verification
- {{STEP}}
