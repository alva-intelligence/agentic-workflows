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

_Pulled verbatim from `features[{{FEATURE_SLUG}}].brainstorming.summary`. Followed by the decided questions/answers._

{{BRAINSTORMING_SUMMARY}}

### Decisions

- **{{QUESTION_1_PROMPT}}** → {{QUESTION_1_ANSWER}}
- **{{QUESTION_2_PROMPT}}** → {{QUESTION_2_ANSWER}}

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

## UI/UX

### Key Screens

{{SCREENS}}

### Mock-data Notes

_Only when `implementation_strategy === "wireframe_then_implementation"`. List the mock-data fixtures the web service will build first._

{{MOCK_DATA_NOTES}}

## Data Model

### New Tables

{{TABLES}}

### Modified Tables

{{MODIFIED_TABLES}}

## API Endpoints

| Method | Endpoint | Description | Service |
|--------|----------|-------------|---------|
| {{METHOD}} | {{ENDPOINT}} | {{DESCRIPTION}} | {{SERVICE}} |

## Acceptance Criteria

- [ ] AC-1: {{CRITERIA}}

## Open Questions

- [ ] Q-1: {{QUESTION}}
