## Workflow Rules (STRICT ENFORCEMENT)

### You are the orchestrator

There is no agent roster and no pre-defined workflow agents. **The current agent IS the workflow
driver — the orchestrator.** It does four things directly — **verify, research, plan, orchestrate,
verify again**:

1. **Verify user claims.** Before acting on any user assertion ("it's broken", "the API supports
   this", "we already migrated X"), check the real state: read code, run the check, query the
   service. User recollection is a hypothesis, not a fact.
2. **Research & plan.** Load real service state, resolve ambiguity, produce the plan and its
   artifacts (see phase sections).
3. **Orchestrate implementation.** Delegate implementation to **subagents, as parallel as possible**
   (see Subagent Orchestration below). The orchestrator writes project code only for trivial
   one-file touch-ups; everything non-trivial goes to subagents.
4. **Verify all work.** A subagent saying "done" is a **claim, not a fact**. Re-run the checks,
   review the diff, and visual-test UI work yourself. Never ship on trust.

### Subagent Orchestration

Implemented via the harness's delegation capability when available: pi's `subagent` tool (batched
tasks, `needs` dependency edges, per-task model + thinking level), Claude Code's Task/subagents, Amp
threads, or equivalent. If the harness has no delegation capability, the orchestrator implements
sequentially itself and says so.

Rules:

- **Parallel first.** Batch all independent service tasks in ONE delegation (one call with a task
  list), not many sequential calls. Use dependency edges only when ordering genuinely matters.
- **Right model and effort.** Match each task to model + reasoning effort if the harness allows it
  (e.g. `subagent_models` in pi): heavy reasoning for architecture/plan/review work, cheap fast
  models for mechanical edits.
- **Isolated writes.** Write tasks run in their own worktree/branch and report the branch — the
  orchestrator merges.
- **Subagent scope.** Each implementation subagent covers a service end-to-end: implement, verify
  its own work (lint, tests, affected commands), and **visual-test UI work if possible**. Subagents
  NEVER ask the user directly and NEVER open PRs or advance phases.
- **Intercom — main ↔ subagent.** If the harness supports mid-run messaging with a running
  subagent (pi's `steer_subagent` / `reply_subagent`, or equivalent), use it: steer drifting work,
  answer subagent questions without killing the run. Subagents that need a user decision return one
  structured question in their output instead of blocking.
- **Intercom — subagent ↔ subagent.** If the harness supports sibling-to-sibling messaging (team
  mailboxes, shared task lists), let subagents coordinate directly for interface details (shared
  types, API contracts, fixture shapes) while the orchestrator stays the single source of truth for
  decisions. If unsupported, brokers all cross-subagent coordination through the orchestrator.
- **The orchestrator validates everything it receives**: re-run the checks, read the diff against
  the ticket, and run the visual-testing skill on anything claiming to render.

### Parallel features (git worktrees)

Latest models work fine across git worktrees — no special tooling required.

- When the user asks for a second concurrent feature, or wants to start one mid-task, **propose
  working in parallel via git worktrees**: one dedicated worktree per affected service repo, per
  feature, so branches never collide with the active checkout.
- On approval: `git worktree add <path> -b <branch> <base>` per service, run the parallel session
  there, and keep `.workflow-state.json` keyed by slug. Cleanup with `git worktree remove` at
  completion.
- Do not propose worktrees for a single linear feature — that is just the ordinary branch flow.

### Phase Machine

```
idle → brainstorming → [features: prd_creation → prd_splitting] → implementation
     → pr_submission → [pr_review?] → completion → idle
```

- `pr_review` is conditional: clean merge with zero feedback goes straight to `completion`.
- **Bug/improvement path:** `brainstorming → implementation` directly — no PRD, no PRD split
  (comprehensive PRDs are for features). Branch creation happens at implementation entry.
- `prd_creation`/`prd_splitting` are feature-only phases.

### Skip & ask rules (stricter than they used to be)

1. **Obvious answer → decide, don't ask.** If a decision is obvious from the codebase, prior PRDs,
   service conventions, or plain best practice, take the best answer, record it as a decided fact
   in the summary, move on. Asking is for genuinely ambiguous, taste, or expensive-to-reverse calls
   only. A brainstorm with **zero questions** is a legitimate outcome.
2. **"No" is an acceptable answer.** Never bury a no-option; when the user says "no", stop that
   work cleanly and record it.
3. **Skip requests honored.** If the user says "skip brainstorming/PRD", jump to the matching phase
   and record the decision as `user_skipped`.
4. **NEVER modify develop/development directly.** Work goes on `<prefix>vc-<slug>` where `<prefix>`
   is `feature/` | `fix/` | `improvement/` per `features[<slug>].type`.
5. **CHECK `.workflow-state.json` before ANY work; UPDATE it after every state change** — phase
   entry, `phase_status` flip, transition.
6. **CHECK the git branch matches the expected branch for the phase** before doing any work.
7. **Wait for the user before advancing.** When `phase_status` becomes `completed`, present the
   outcome and ask whether to advance.

### `phase_status` and `agent_state` (state discipline)

- `phase_status`: `idle` (entered, not started) → `inprogress` (agent working) → `completed` (gate
  satisfied). `completed` does NOT auto-advance; the user triggers transition explicitly (the
  orchestrator may transition at user direction). Orchestrator flips `idle → inprogress` on real
  work, sets `idle` on entering a new phase.
- `agent_state` surfaces when the user should step in:

| Situation                    | `agent_state`    |
|------------------------------|------------------|
| Plan ready, awaiting approve | `needs_approval` |
| Asked a structured question  | `needs_answer`   |
| Stuck, free-form input needed | `needs_human`   |
| Working / resumed            | `null`           |

Triggers: set `needs_approval` right BEFORE presenting the plan for approval; `needs_answer` right
BEFORE asking a question; `needs_human` BEFORE printing a free-form blocker; on resume, clear both
fields (`agent_state = null`, `agent_state_reason = null`) as the FIRST action. `agent_state_reason`
is non-empty whenever `agent_state` is non-null, and both are `null` together (schema-enforced).

### Asking the user (single protocol)

There are no agent tiers anymore — one protocol covers everything:

- Gather genuinely unresolved decisions into **one structured ask** (up to 4 questions, one
  `recommended: true` option each). Never drip-feed.
- Subagents NEVER ask the user. Their `open_questions[]` land with the orchestrator, which folds
  them into its next ask (or resolves them itself under the obvious-answer rule, marking
  `assumed_answer` + rationale in the artifact).
- Harness conditionals: before a plan-approval ask, trigger the harness's plan mode (pi
  plan-command, Claude Code `ExitPlanMode`) with `agent_state = "needs_approval"`. Before any ask,
  set `agent_state = "needs_answer"`.
- A subagent blocked on a destructive-or-ambiguous call returns `status: "blocked"` +
  `open_questions[].blocks = true`; the orchestrator surfaces it to the user rather than guessing.

### Brainstorming phase

1. Load the real state of every relevant service (paths, key symbols, recent changes — grep/read
   first; web search for external SDK/API/framework behavior). No code-graph MCP anywhere.
2. **Resolve ambiguity in order:** (a) codebase exploration, (b) web search, (c) your own best
   judgment when the answer is obvious or convention decides, (d) only if genuinely ambiguous →
   ask the user.
3. Decided-by-judgment items go into `summary` as facts with a one-line rationale — NOT into
   `open_questions`. `open_questions` holds only true user-input decisions (often zero).
4. Write `summary`; flip `phase_status` to `completed`; stop and present. Skill:
   `skills/brainstorm/SKILL.md`.

### Feature-only writer phases

- `prd_creation`: author the main PRD from the brainstorming summary (skill `prd`). For
  bug/improvement work, this phase never runs.
- `prd_splitting`: from latest base, create `<prefix>vc-<slug>`, split main PRD into per-service
  PRDs (skill `prd-split`). Feature-only — implementation after bugs/improvements creates the
  branch itself.

### Implementation phase

1. Enter: verify branch state. Feature path → on `<prefix>vc-<slug>` already. Bug/improvement
   path → create `<prefix>vc-<slug>` from the latest base now.
2. Orchestrate per Subagent Orchestration: parallel per-service subagents, sequential dependency
   edges, per-task model/effort.
3. Update the track file as subagents complete; reconcile their checks against your own.
4. On completion of every service: verify (lint + tests + targeted behavior checks), visual-test
   UI paths via `skills/visual-testing/SKILL.md`, then `phase_status = completed` and present.

### PR submission phase

Before opening the PR:

1. **Self code-review** of the whole diff: correctness, lint, tests, project conventions — the
   orchestrator may delegate a fresh-eyes review subagent, but owns the result. Written summary,
   no must-fix items remaining.
2. **Security audit** via the `security-reviewer` skill (install:
   `npx skills add https://github.com/jeffallan/claude-skills --skill security-reviewer`). Written
   summary, no high/critical findings remaining.
3. Open the PR; body includes both summaries. PRD links only when a PRD exists (bugs/improvements).

### PR review phase

PR has reviewer/bot feedback. Load `skills/pr-feedback/SKILL.md`: inventory every thread (GraphQL),
classify (must-fix / nit / question), fix or reply with rationale, resolve every thread — loop
until zero open threads. Do not re-request review unless the user says so.

### Sandbox-blocked operations are advisories, not failures

Auto-mode sandboxes may block a tool call that actually succeeded (e.g. writes through
symlink-shared dirs like `docs/`, `.agentic-workflows/`, `.agents/`). When a block is returned BUT
canonical state confirms the write (`.workflow-state.json` updated, file exists on re-read):

- Log a one-line note: `sandbox-blocked verify, state confirms`.
- Do NOT flip `agent_state`, roll back state, or retry destructively (`rm`, `--force`).

A block on a write that did NOT persist IS a real failure — surface it, set
`agent_state = "needs_human"` with the reason, and stop.

### Context switching & handoff

- `/workflow switch <feature-slug>` — switch between active features
- `/workflow resume <slug>` — reconstruct phase from committed artifacts; run the branch recency +
  service-health checks from `skills/workflow/references/session-checks.md`.

### Steps requiring sudo or external terminal

See `skills/onboard/references/external-steps.md` — tell the user what to run, block on the ask
tool until they confirm, verify it worked.
