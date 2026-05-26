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

**Every `phase_status` flip MUST be followed by `/lark-sync push <slug>`** (advisory; log + continue on failure). Without this, the Lark task's `Phase status` custom field drifts from local state and the team's kanban view goes stale. Same rule applies to loki card mutations: any GUI mutation of `.workflow-state.json` fires `/lark-sync push <slug>` fire-and-forget.

### `agent_state` Semantics (CRITICAL)

Every feature has `agent_state` and `agent_state_reason` fields. They surface the agent's current attention need to the loki GUI shell and orchestra so the user knows when to step in.

| Situation                       | `agent_state`     |
|---------------------------------|-------------------|
| Plan ready, await approve       | `needs_approval`  |
| Asked structured question       | `needs_answer`    |
| Stuck, need free-form input     | `needs_human`     |
| Working / resuming              | `null`            |

**Triggers — when agents MUST update these fields:**

1. **Right BEFORE calling `ExitPlanMode`:** set `agent_state = "needs_approval"`, `agent_state_reason = "<short summary of the plan>"`. The plan-mode prompt itself is the user's chance to approve.
2. **Right BEFORE calling `AskUserQuestion`:** set `agent_state = "needs_answer"`, `agent_state_reason = "<the question topic in 1 line>"`.
3. **When stuck on a free-form decision** (no structured options, requires human judgment / context the agent lacks): set `agent_state = "needs_human"`, `agent_state_reason = "<what's blocking>"` BEFORE printing the blocker message.
4. **When work resumes** (user approved plan, user answered question, user unblocked): set `agent_state = null`, `agent_state_reason = null` as the FIRST action after resuming, before any other tool call.

**Pairing rule (enforced by schema):** `agent_state_reason` MUST be a non-empty string whenever `agent_state` is non-null, and MUST be `null` when `agent_state` is `null`. Never set one without the other.

**Lark sync:** every `agent_state` mutation MUST be followed by `/lark-sync push <slug>` (fire-and-forget, same rule as `phase_status`).

### Sandbox-Blocked Operations Are Advisories, Not Failures

Auto mode (`https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode`) wraps tool calls in a sandbox. Two classes of advisory blocks happen routinely in this workflow and MUST NOT be treated as fatal:

1. **Symlink-target writes through `docs/`, `.agentic-workflows/`, `.agents/`** in JJ secondary workspaces. These dirs symlink to the primary workspace (sibling path). The secondary's `.claude/settings.local.json` registers the primary in `additionalDirectories` — but stale settings, multi-hop symlinks, or pre-`/jj-workflow new` workspaces may still surface a sandbox block on the verify step (e.g. `stat`, `ls -la`, `cat`).
2. **`/lark-sync push` and any `lark-cli api ...` network call** — already advisory by definition (see lark-sync skill).

**Rule:** when a Bash/Edit/Write returns a sandbox-block error AND the canonical state confirms the write went through (`.workflow-state.json` updated, file exists per a separate read, `phase_status` mutation persisted), the agent MUST:

- Log a one-line note: `sandbox-blocked verify, state confirms` (or equivalent for the specific case).
- **NOT** flip `agent_state` to `needs_human` — sandbox advisories are not human-blocking.
- **NOT** roll back `phase_status` or undo prior writes.
- **NOT** retry with destructive workarounds (`rm`, `--force`, etc).
- Continue the phase normally.

Conversely, a sandbox block on a write that did NOT persist (state inspection shows the change is missing) IS a real failure — surface it, set `agent_state = "needs_human"`, `agent_state_reason = "sandbox blocked write to <path>; settings.local.json may be missing additionalDirectories entry for <primary>"`, and stop.

### Phase Transition Rules

1. **NEVER skip a phase.** If the user asks to skip, respond: "I cannot skip phases. Current phase: [PHASE]. Required gate: [GATE]." Exception: `pr_submission → completion` is a legitimate transition (clean merge), not a skip.
2. **NEVER start implementation before service PRDs exist AND a feature branch is created.** Both happen in `prd_splitting`.
3. **NEVER modify develop/development branch directly.** Work goes on `<prefix><worker>/vc-<slug>` where `<prefix>` is `feature/` | `fix/` | `improvement/` per `features[<slug>].type`.
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
| prd_splitting | `develop` (or `development`) → creates `<prefix><worker>/vc-<slug>` (prefix per type) |
| implementation → completion | `<prefix><worker>/vc-<slug>` |

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

1. Load latest state of every relevant service (paths, key symbols, recent changes — `code-review-graph` MCP tools first, fall back to grep/read). Use web search/fetch for external SDK/API/framework behavior.
2. **Grill protocol:** walk every branch of the decision tree implied by `initial_request`. Resolve each ambiguity in order: (a) codebase exploration, (b) web search, (c) only if neither resolves it, author a multi-choice question. No quotas — no minimum or maximum on question count or options per question. Exactly one option per question carries `recommended: true`.
3. **Drop resolved questions.** Any question answered via codebase or web becomes a fact in `summary`, NOT an `open_questions` entry. `open_questions` contains ONLY truly unresolved decisions that need user input.
4. Do NOT call the ask tool. Do NOT self-resolve under `assumed_answer`. Return `open_questions[]` as `{id, topic, options[], recommended_label, rationale}` — no `assumed_answer` field.
5. Write a `summary` capturing facts resolved via exploration. Flip `phase_status` to `completed` and stop.
6. **Orchestra asks the user one question at a time** (Mode A relay in `frndos-orchestra.md`) — never batch brainstorm questions.

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

### Ask-User Protocol — Two Tiers

Agents fall into **two tiers** with different user-interaction rules. Pick the right tier by agent name before doing anything else.

**Tier 1 — Implementation agents:** `frndos-implement`, `frndos-engineer`.

These agents write code and MUST be interactive:
1. **Explain** the plan before changing files
2. **Ask** via the ask tool (`AskUserQuestion` / equivalent) when requirements are unclear
3. **Wait for user confirmation** before executing destructive or non-trivial changes
4. NEVER auto-advance phases when `phase_status` flips to `completed`

**Tier 2 — Non-implementation agents:** `frndos-brainstorm`, `frndos-prd`, `frndos-splitter`, `frndos-architect`, `frndos-pr`, `frndos-pr-review`, `frndos-track`.

These agents are **non-interactive**. They MUST NOT call `AskUserQuestion` (or the tool's equivalent) mid-task. Instead, they follow the **Batched Open-Questions Protocol** below. Rationale: every mid-task ask forces the main thread to wait, ping-pong context, and re-spawn the agent. Batching everything to the final output lets the main thread ask the user once with all the context in hand.

**Tier 3 — Router:** `frndos-orchestra`.

Orchestra is the user-facing router that bridges user ↔ sub-agents. It IS allowed to ask the user — that is its job. Sub-agents return `open_questions` in their final output; orchestra reads them, asks the user, then re-delegates with answers attached.

### Batched Open-Questions Protocol (Tier 2)

**Exception — `frndos-brainstorm`** does NOT self-resolve under `assumed_answer`. It drops every codebase/web-resolved question into `summary` and returns only truly unresolved questions in `open_questions` with no `assumed_answer` field. Orchestra asks brainstorm questions one at a time (Mode A relay). The rest of this section applies to other Tier 2 agents (prd, splitter, pr, pr-review, architect, track).

Tier 2 agents follow this loop:

1. **Run all research and work first.** Use code-graph MCP, grep, file reads, MCP servers, etc. Produce the artifacts the phase demands (snapshots, PRD draft, split, review notes).
2. **When ambiguity hits**, do NOT stop. Pick the **safest reasonable default**:
   - If you generated a multi-choice question with a `recommended: true` option, pick the recommended option.
   - Otherwise pick the option that's lower-friction, aligns better with existing system behavior, or is the smallest reversible step.
   - Record the choice as an **assumption** in the agent's scratch output: `assumption: <decision>, rationale: <one line>`.
3. **Collect every assumption + every still-unanswered question** into a single `open_questions` array on the final output. Each entry has:
   - `id`: short slug (e.g. `q-flag-scope`)
   - `topic`: 1-line summary
   - `options`: array of `{label, description, recommended}` — exactly one `recommended: true`
   - `assumed_answer`: the option label you picked (if you self-resolved); `null` if you couldn't pick
   - `rationale`: 1-line why
   - `blocks`: `false` if you proceeded under the assumption; `true` if the agent had to stop early
4. **Finish all reachable work** under those assumptions. Write artifacts (PRDs, summaries, state) reflecting the assumed answers. Mark assumed answers clearly in the artifact (e.g. `*(assumed — see open_questions[q-flag-scope])*`).
5. **Return to main thread** with the artifact + `open_questions`. The main thread (or orchestra) asks the user, then re-invokes the agent with `answers: {q-id: chosen_option}` to finalize.

**Hard blocker exception:** if the agent literally cannot proceed at all (e.g. required input file missing, external system unreachable, no `recommended:true` option fits and any pick would be destructive), return early with `status: "blocked"` and the blocker in `open_questions[].blocks = true`. Do NOT call `AskUserQuestion`.

**State writes still happen.** Tier 2 agents still flip `phase_status` to `inprogress` on entry and `completed` when their gate is satisfied — even if open questions remain. Open questions are review items for the next phase, not phase blockers, unless `blocks: true` is set on any entry.

### Parallel features (JJ workspaces)

When JJ is available and the user wants to work on multiple features in parallel, they can use `/jj-workflow` to spin up isolated workspaces. Full rules: `skills/jj-workflow/references/rules.md`.

**Loki coexistence:** if `.loki/marker.json` exists at the workspace root, loki (the Claude Code GUI) is managing isolation via its own git worktrees. In that case, every `/jj-workflow` subcommand is a no-op that prints a redirect message. Do not suggest `/jj-workflow new` for parallel features in a loki-managed workspace — tell the user to add a card in the GUI instead.

### Agent Teams (parallel implementation)

When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, the `implementation` phase uses parallel per-service engineers instead of a single sequential agent (implementation → completion, skipping pr_submission/pr_review). Full protocol: `skills/workflow/references/agent-teams.md`.

### Steps requiring sudo or external terminal

See `skills/onboard/references/external-steps.md` — tell the user what to run, block on the ask tool until they confirm, verify it worked.
