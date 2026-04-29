## Workflow Rules (STRICT ENFORCEMENT)

### 8-Phase State Machine

```
idle → brainstorming → prd_creation → prd_splitting → implementation
     → pr_submission → [pr_review?] → completion → idle
```

`pr_review` is conditional: from `pr_submission`, the workflow advances directly to `completion` when the PR merges with no reviewer/bot feedback. It only enters `pr_review` when feedback exists.

### `phase_status` Semantics (CRITICAL)

Every feature has a `phase_status` field on top of `phase`:

- `idle` — phase entered, agent has not started work yet
- `inprogress` — agent actively working
- `completed` — phase's gate conditions are satisfied (artifacts produced, checks pass)

**`completed` does NOT auto-advance.** The workflow stays on the phase until the user (or orchestra at user direction) explicitly triggers transition. Agents MUST flip `phase_status` to `completed` once their work is done, then **stop and ask the user** before transitioning.

Agents MUST flip `phase_status` from `idle` to `inprogress` when they begin their actual work. Orchestra sets `phase_status` to `idle` when entering a new phase.

**Every `phase_status` flip MUST be followed by `/lark-sync push <slug>`** (advisory; log + continue on failure). Without this, the Lark task's `Phase status` custom field drifts from local state and the team's kanban view goes stale. Same rule applies to korlap card mutations: any GUI mutation of `.workflow-state.json` fires `/lark-sync push <slug>` fire-and-forget.

### Phase Transition Rules

1. **NEVER skip a phase.** If the user asks to skip, respond: "I cannot skip phases. Current phase: [PHASE]. Required gate: [GATE]." Exception: `pr_submission → completion` is a legitimate transition (clean merge), not a skip.
2. **NEVER start implementation before service PRDs exist AND a feature branch is created.** Both happen in `prd_splitting`.
3. **NEVER modify develop/development branch directly.** Features go on `feature/<worker>/vc-<slug>`.
4. **CHECK `.workflow-state.json` before ANY work.**
5. **UPDATE `.workflow-state.json` after every state change** — phase entry, `phase_status` flip, transition.
6. **CHECK current git branch matches the expected branch for the phase** before doing any work.
7. **Wait for user before advancing.** When `phase_status` becomes `completed`, present the outcome and ask whether to advance.

### Branch per Phase

| Phase | Expected Branch |
|-------|----------------|
| idle | any |
| brainstorming | any (no code changes) |
| prd_creation | any (PRDs are in docs/, not branch-specific) |
| prd_splitting | `develop` (or `development`) → creates `feature/<worker>/vc-<slug>` |
| implementation → completion | `feature/<worker>/vc-<slug>` |

### Gate Conditions (summary)

| Transition | Gate | Check |
|-----------|------|-------|
| idle → brainstorming | Intake recorded (slug, type, initial_request) | State |
| brainstorming → prd_creation | Every question answered, summary written | State |
| prd_creation → prd_splitting | PRD frontmatter + sections valid (incl. `Brainstorming Outcome` section) | File |
| prd_splitting → implementation | Feature branch created from base + service PRDs exist | Git + File |
| implementation → pr_submission | Track progress, on feature branch, sequential strategy | File + Git |
| pr_submission → pr_review | PR open, self-review + security audit recorded, has reviewer/bot feedback | `gh` |
| pr_submission → completion | PR open, self-review + security audit recorded, MERGED with zero feedback | `gh` |
| pr_review → completion | All review threads resolved, PR merged | `gh` |
| completion → idle | Track file marked complete | File |

Every gate also requires `phase_status === 'completed'`.

### Brainstorming phase — what the agent does

1. Load latest state of every relevant service (paths, key symbols, recent changes — `code-review-graph` MCP tools first, fall back to grep/read).
2. Generate a small set of pointed multi-choice questions (2–4 options each). Exactly one option per question carries `recommended: true`.
3. Ask the user via the ask tool, one question per ask call (or batched per the tool's limits). Record the answer.
4. After the last answer, write a `summary` capturing the chosen direction, then flip `phase_status` to `completed` and stop.

Skill: `skills/brainstorm/SKILL.md`.

### Implementation phase — wireframe-first option (web only)

On entering `implementation`, if `service_prds` includes web work, the agent asks the user via the ask tool:

> "Build the web UI on the feature branch with mock/static data first (then swap stubs for real API calls), or jump straight to full implementation?"

Recommended option = wireframe-first when the UI is non-trivial.

The choice is recorded in `features[active_feature].implementation_strategy`:

- `"wireframe_then_implementation"` — UI first with mock data, same feature branch, no separate PR, no FE-owner approval.
- `"implementation_only"` — straight implementation.

There is **no separate wireframe phase, branch, PR, scaffold, or skill**.

### PR submission phase — frndos-pr responsibilities

`frndos-pr` runs **before** opening the PR:

1. **Self code-review** on its own diff: correctness, lint, tests, project conventions. Must produce a written summary with no must-fix items remaining.
2. **Security audit** via the `security-reviewer` skill (install: `npx skills add https://github.com/jeffallan/claude-skills --skill security-reviewer`). Must produce a written summary with no high/critical findings remaining.
3. Only then opens the PR. PR body includes both summaries.

### PR review phase — frndos-pr-review responsibilities

`frndos-pr-review` owns `pr_review`:

1. Polls the PR for unresolved threads, change requests, and bot findings (CodeRabbit, GitHub Actions, etc.).
2. For each thread: classify (must-fix / nit / question), draft a fix or reply, apply, push, mark thread resolved.
3. Loop until `gh pr view --json reviewDecision,comments,reviews` shows zero open threads.
4. Flip `phase_status` to `completed` and stop.

### Context Switching & Handoff

- `/workflow switch <feature-slug>` — switch between active features
- `/workflow resume <slug>` — pick up someone else's feature; the agent reconstructs phase from committed artifacts

### Always Ask Before Executing

**MANDATORY for every agent:** Before performing ANY action:
1. **Explain** what you plan to do and why
2. **Ask questions** if anything is unclear — use the ask tool (Claude Code: `AskUserQuestion`; Cursor: ask tool; OpenCode: question tool; Amp: ask as plain text and wait)
3. **Give suggestions** if there are multiple valid approaches
4. **Wait for user confirmation** before executing

NEVER execute code changes without explaining the plan first. NEVER make assumptions about requirements without asking. NEVER skip confirmation. NEVER auto-proceed after presenting a plan. NEVER auto-advance phases when `phase_status` flips to `completed`.

### Parallel features (JJ workspaces)

When JJ is available and the user wants to work on multiple features in parallel, they can use `/jj-workflow` to spin up isolated workspaces. Full rules: `skills/jj-workflow/references/rules.md`.

**Korlap coexistence:** if `.korlap/marker.json` exists at the workspace root, korlap (the Claude Code GUI) is managing isolation via its own git worktrees. In that case, every `/jj-workflow` subcommand is a no-op that prints a redirect message. Do not suggest `/jj-workflow new` for parallel features in a korlap-managed workspace — tell the user to add a card in the GUI instead.

### Agent Teams (parallel implementation)

When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, the `implementation` phase uses parallel per-service engineers instead of a single sequential agent (implementation → completion, skipping pr_submission/pr_review). Full protocol: `skills/workflow/references/agent-teams.md`.

### Steps requiring sudo or external terminal

See `skills/onboard/references/external-steps.md` — tell the user what to run, block on the ask tool until they confirm, verify it worked.
