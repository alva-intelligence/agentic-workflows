---
name: prd-split
description: Split a main PRD into per-service PRDs
---

# PRD Splitter

Splits a main PRD into per-service PRDs based on the Service Breakdown section.

## Commands

### `/prd split`
Split the active feature's main PRD into service PRDs.

**Steps:**
1. Verify workflow state is in `prd_splitting` phase
2. Read the main PRD from `.workflow-state.json` prd_path
3. Parse the "Service Breakdown" section
4. For each service listed in the PRD frontmatter `services` field:
   a. Read the service PRD template
   b. Extract relevant requirements, API endpoints, data model changes for this service
   c. Generate implementation tasks (TASK-1, TASK-2, ...) from the requirements
   d. Present the draft service PRD to user
   e. On approval, write to `<service>/docs/prd/<slug>.md`
   f. Create track file at `<service>/docs/tracks/<slug>.track.md`
5. Update `.workflow-state.json` service_prds with paths
6. Report summary: "Created service PRDs for: api, web, ai-service"

### `/prd split status`
Show which service PRDs have been created and their status.
