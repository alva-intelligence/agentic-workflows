---
name: prd-split
description: Split a main PRD into per-service PRDs during automatic preparation after scope approval (feature path only)
---

# PRD Splitter

Owns `prd_splitting` for features. Runs automatically after the main PRD exists — no per-service
approval loop. It creates the feature branch locally, splits the main PRD into per-service PRDs,
and prepares each track with its task plans and verification plans. It does **not** push the branch
before implementation approval and does not ask the user to approve each document.

**Read `references/conventions.md` first** for the service-PRD frontmatter, required sections
(including Plan, Verification, and Delivery), and the naming convention shared with main PRDs.

## Commands

### `/prd split`
Split the active feature's main PRD into service PRDs.

**Steps:**

0. **Guard.** Verify `features[active_feature].type === "feature"`. Bugs/improvements never enter
   this phase. Verify `scope_approved === true`; if not, return to the scope checkpoint.

1. **Activate phase.** Flip `features[active_feature].phase_status` to `"inprogress"` in
   `.workflow-state.json`.

2. **Create the branch locally (before splitting).**
   - Determine the base branch from the service registry: `develop` for api/web/desktop,
     `development` for ai-service/data-service/data-pipeline.
   - Resolve the branch prefix from `features[<slug>].type`: `feature` → `feature/`, `bug` →
     `fix/`, `improvement` → `improvement/`. If the type is missing/unknown, ask once and persist
     the answer; do not guess.
   - Branch name: `<prefix>vc-<slug>`.
   - `git fetch origin`, switch to the base, fast-forward it, then `git switch -c
     <prefix>vc-<slug>`.
   - If the branch already exists, verify it is the expected branch and base it on the latest base
     without rewriting history. Do not recreate it.
   - Record `features[<slug>].branch` in `.workflow-state.json`.
   - **Do not push yet.** The push happens after implementation approval, when implementation
     starts, unless the user explicitly asked for an earlier push.
   - If the user explicitly skipped the main PRD, the branch still gets created here; the service
     split comes from the approved scope summary rather than a fabricated PRD.

3. **Read the approved scope input.** Normally `features[active_feature].prd_path` points at the main PRD; parse its Service Breakdown section and frontmatter `services`. If the user explicitly skipped the main PRD, read the approved `brainstorming.summary` and `initial_request` instead, keep the skip recorded in `brainstorming.decisions[]`, and do not fabricate a PRD.

4. **Research each service enough to split correctly.** Read existing patterns for similar
   endpoints/components/models, integration points, and active work in `<service>/docs/tracks/` that
   could conflict. No code-graph MCP; grep/read.

5. **Split without a per-document approval.** For each service in the main PRD frontmatter (or
   the approved scope summary when the PRD was skipped):
   a. Read the service PRD template.
   b. Extract the service's requirements, API contracts, data changes, dependencies, and risks.
   c. Generate implementation tasks (TASK-1, TASK-2, ...) from the requirements.
   d. For every task, write the plan (approach, touched areas, dependencies, risk) and the
      verification plan (risk level, exact checks, expected evidence). Scale to risk; do not add
      new test dependencies.
   e. Write `<service>/docs/prd/<slug>.md`.
   f. Create `<service>/docs/tracks/<slug>.track.md` from the track template, with the tasks,
      plans, verification plans, `execution_mode` resolved default, `delivery: null`, and
      `live_merge_approved: false`.
   g. If a service-splitting decision is genuinely ambiguous and changes scope, collect it into one
      ask. Do not ask for approval of the service PRD itself.

6. **Update state and continue automatically.** Set `service_prds` paths, flip `phase_status` to
   `"completed"`, and move to `implementation`. No `/workflow next` ceremony.

7. **Leave one preparation summary** for the implementation checkpoint: branch, services, track
   paths, task counts, risk levels, and anything that needs the implementation decision. Do not ask
   the user to review each document.

### `/prd split status`
Show which service PRDs and tracks have been prepared for the active feature, and their status.
