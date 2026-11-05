---
title: {{FEATURE_TITLE}}
slug: {{FEATURE_SLUG}}
author: {{AUTHOR}}
created: {{DATE}}
status: draft
services: [{{SERVICES}}]
---

# {{FEATURE_TITLE}}

## Overview

{{OVERVIEW}}

## Brainstorming Outcome

_Scope approved during the scope checkpoint. Pulled from `features[{{FEATURE_SLUG}}].brainstorming`._

{{BRAINSTORMING_SUMMARY}}

### Decisions

- **{{DECISION_TOPIC}}** → {{DECISION}} — _{{DECISION_RATIONALE}}_

### Questions Asked

- **{{QUESTION_1_PROMPT}}** → {{QUESTION_1_ANSWER}}

## Decisions & Assumptions

_Assumptions made while authoring this PRD, each with its rationale. Do not leave an assumed
answer implicit._

- **{{ASSUMPTION_TOPIC}}** → {{ASSUMPTION}} — _{{ASSUMPTION_RATIONALE}}_

## User Stories

{{USER_STORIES}}

## Requirements

### Functional Requirements

- **FR-1:** {{REQUIREMENT}}

### Non-Functional Requirements

- **NFR-1:** {{REQUIREMENT}}

## Service Breakdown

### API (`api/`)

{{API_SCOPE}}

### Frontend (`web/`)

{{WEB_SCOPE}}

### AI Service (`ai-service/`)

{{AI_SCOPE}}

### Data Service (`data-service/`)

{{DATA_SCOPE}}

### Data Pipeline (`data-pipeline/`)

{{DATA_PIPELINE_SCOPE}}

### Hocuspocus (`hocuspocus/`)

{{HOCUSPOCUS_SCOPE}}

## UI/UX

### Key Screens

{{SCREENS}}

## Data Model

### New Tables

{{TABLES}}

### Modified Tables

{{MODIFIED_TABLES}}

## API Endpoints

| Method | Endpoint | Description | Service |
|--------|----------|-------------|---------|
| {{METHOD}} | {{ENDPOINT}} | {{DESCRIPTION}} | {{SERVICE}} |

## Planning & Verification

_Reference the shared contract in `.agents/skills/workflow/references/track-conventions.md`. Do not
duplicate the full delivery/merge policy here._

- **Risk level:** low / medium / high (auth, data, migration, live estate, cross-service contract = high).
- **Plan:** <approach, touched areas, dependencies, risks>.
- **Verification plan:** <exact existing checks, manual steps, expected evidence>.
- **Adversarial review:** <when high risk or when an independent pass is useful>.
- **Rollback/recovery:** <how to undo, when relevant>.

No new test dependency is added for verification. Existing targeted tests/lint/checks are allowed
and default. Leave one small runnable regression check for non-trivial logic; reuse existing checks
where sufficient. Never call these checks formal verification or a formal proof.

## Delivery & Rollout

_Delivery authorization is per task and lives in workflow state/track. This section records
constraints only._

- **Live estate:** {{LIVE_ESTATE}} (yes for `data-pipeline` even on its development branch).
- **Rollout constraints:** {{ROLLOUT}}
- **Observability / monitoring:** {{MONITORING}}
- **Rollback:** {{ROLLBACK}}

## Acceptance Criteria

- [ ] AC-1: {{CRITERIA}}

## Open Questions

- [ ] Q-1: {{QUESTION}}
