## SESSION START PROTOCOL (MANDATORY)

**This protocol MUST be executed before ANY other work. No exceptions.**

### Step 0: Detect workspace state

1. **No service directories** (none of `api/`, `web/`, `ai-service/`, `data-service/`,
   `data-pipeline/`, `desktop/` exist) → Fresh workspace. Ask: "This workspace hasn't been set up
   yet. Would you like to start onboarding now?" On yes, execute `skills/onboard/SKILL.md`
   directly. On no, tell the user they can run `/onboard` later.
2. **`.onboard-state.json` exists and `status` is `"in_progress"`** → Check `env_status`,
   `steps.db_setup`; if critical items are missing, tell the user to run `/onboard resume` or
   `/onboard verify`. Block workflow commands until resolved. **`env_status` of `"n/a"` counts as
   resolved, not missing** — no `.env` by design (data-pipeline uses Prefect Secret blocks). Only
   `"pending"` blocks.
3. **`.onboard-state.json` completed (or absent with services present)** → Proceed. If
   `.workflow-state.json` is missing, welcome the user and point at
   `/workflow start <feature-slug>`, `/workflow list`.
4. **`.workflow-state.json` exists** → Proceed through the remaining steps.

### Optional services: data-pipeline (frnd-orchestration) and desktop (frnd-desktop)

`data-pipeline/` (frnd-orchestration — Prefect data orchestration) and `desktop/` (frnd-desktop —
native SwiftUI macOS app) are **optional services**; a developer may legitimately not have them
cloned. When the user's request touches their domain:

- data-related orchestration/flow/pipeline work → needs `data-pipeline/`; native desktop-app work →
  needs `desktop/`.
- If the directory is **absent**, stop and recommend onboarding it first (execute the matching
  onboarding path in `skills/onboard/SKILL.md` when the user agrees). Do not silently skip a
  service the request clearly needs.
- If the user's request doesn't touch them, they stay out of the way.

### Step 1: Check for instruction updates + sync

Run the update-check script and sync the current branch. Detailed procedure (including dependency
bootstraps and conflict handling): `skills/workflow/references/session-checks.md` →
"Update check + sync".

### Step 2: Load workflow state

Read `.workflow-state.json` to determine:
- Which feature is currently active (`active_feature`)
- What phase it's in (`features[active_feature].phase`)
- Who the current worker is (`worker`)

If `.workflow-state.json` doesn't exist, no features are active yet.

### Step 3: Feature branch recency + service health

After pulling, if any service is on a feature branch, run the recency check against its base
branch. Then verify that required services are healthy. Full procedures: the same
`references/session-checks.md`.

### Step 4: Drive the phase as the orchestrator

Based on `.workflow-state.json`, **the orchestrator itself** runs the current phase's work —
loading the matching skill (`brainstorm`, `prd`, `prd-split`, `pr-feedback`, …) — and delegates
implementation to parallel subagents per the Subagent Orchestration rules. There are no named
workflow agents to route to.
