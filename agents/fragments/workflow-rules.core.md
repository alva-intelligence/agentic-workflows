## Workflow Rules (STRICT ENFORCEMENT)

### 11-Phase State Machine

```
idle → prd_creation → wireframe → wireframe_pr → wireframe_review → branch_creation
     → prd_splitting → implementation → pr_submission → pr_review → completion → idle
```

### Phase Transition Rules

1. **NEVER skip a phase.** If user asks to skip, respond: "I cannot skip phases. Current phase: [PHASE]. Required gate: [GATE]."
2. **NEVER create a feature branch before wireframe PR is merged.**
3. **NEVER start implementation before service PRDs exist.**
4. **NEVER modify develop/development branch directly.** Wireframes go on `wireframe/<worker>/vc-<slug>`, features on `feature/<worker>/vc-<slug>`.
5. **CHECK `.workflow-state.json` before ANY work.**
6. **UPDATE `.workflow-state.json` after every phase transition.**
7. **CHECK current git branch matches the expected branch for the phase** before doing any work.

### Branch per Phase

| Phase | Expected Branch |
|-------|----------------|
| prd_creation | any (PRDs are in docs/, not branch-specific) |
| wireframe | `wireframe/<worker>/vc-<slug>` (from develop) |
| wireframe_pr | `wireframe/<worker>/vc-<slug>` (PR targets develop) |
| wireframe_review | `wireframe/<worker>/vc-<slug>` (waiting for merge) |
| branch_creation | `develop` → creates `feature/<worker>/vc-<slug>` |
| prd_splitting → completion | `feature/<worker>/vc-<slug>` |

### Gate Conditions

| Transition | Gate | Check |
|-----------|------|-------|
| prd_creation → wireframe | PRD file with required frontmatter + sections | File |
| wireframe → wireframe_pr | `.tsx` + `metadata.json` committed on `wireframe/<worker>/vc-<slug>` | File + Git |
| wireframe_pr → wireframe_review | Wireframe PR exists targeting develop | `gh` |
| wireframe_review → branch_creation | Wireframe PR merged + Jeff approved | `gh` + Manual |
| branch_creation → prd_splitting | On `develop`, pulled latest, wireframe files verified, feature branch created | Git |
| prd_splitting → implementation | Service PRDs exist, on feature branch | File + Git |
| implementation → pr_submission | Track file shows progress, on feature branch | File + Git |
| pr_submission → pr_review | PR URL recorded and exists | `gh` |
| pr_review → completion | PR merged | `gh` |
| completion → idle | Track file marked complete | File |

### Wireframes and Sub-Pages

A wireframe = **one feature page**. Sub-views (create form, detail page, wizard steps) are sub-pages within the same wireframe directory, not separate wireframes.

- `wireframes` is an array, but most PRDs have **one wireframe** with sub-pages
- Each wireframe has its own `slug`, `owner`, and `approval` status
- `wireframe_review` gate requires ALL wireframes to be approved
- Only the wireframe owner (or unassigned) can create/edit a wireframe
- Multiple wireframes per PRD is rare — only for truly independent feature pages
- Detailed conventions live in `skills/wireframe/references/conventions.md`

### Context Switching & Handoff

- `/workflow switch <feature-slug>` — switch between active features
- `/workflow resume <slug>` — pick up someone else's feature; the agent reconstructs phase from committed artifacts

### Always Ask Before Executing

**MANDATORY for every agent:** Before performing ANY action:
1. **Explain** what you plan to do and why
2. **Ask questions** if anything is unclear — use the ask tool (Claude Code: `AskUserQuestion`; Cursor: ask tool; OpenCode: question tool; Amp: ask as plain text and wait)
3. **Give suggestions** if there are multiple valid approaches
4. **Wait for user confirmation** before executing

NEVER execute code changes without explaining the plan first. NEVER make assumptions about requirements without asking. NEVER skip confirmation. NEVER auto-proceed after presenting a plan.

### Parallel features (JJ workspaces)

When JJ is available and the user wants to work on multiple features in parallel, they can use `/jj-workflow` to spin up isolated workspaces. Full rules: `skills/jj-workflow/references/rules.md`.

### Agent Teams (parallel implementation)

When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, the `implementation` phase uses parallel per-service engineers instead of a single sequential agent (implementation → completion, skipping pr_submission/pr_review). Full protocol: `skills/workflow/references/agent-teams.md`.

### Steps requiring sudo or external terminal

See `skills/onboard/references/external-steps.md` — tell the user what to run, block on the ask tool until they confirm, verify it worked.
