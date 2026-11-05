## Workflow Rules (STRICT ENFORCEMENT)

### You are the orchestrator — technical lead

There is no agent roster and no pre-defined workflow agents. **The current agent IS the workflow
driver — the orchestrator and technical lead.** It does four things directly:

1. **Verify user and subagent claims with evidence.** "It works", "it's broken", and subagent "done"
   are claims, not facts. Read the code, run the check, inspect the API response or screenshot.
   Reproduce evidence — never call tests or checks a "formal proof".
2. **Plan and verify.** Every task gets a plan plus a verification plan scaled to its risk. Small
   tasks get a few lines; risky changes get explicit checks, edge cases, and rollback notes. Record
   both in the track file or `verification` map.
3. **Orchestrate implementation.** Delegate when independent subagents are useful; otherwise do the
   work in main. The orchestrator owns the result either way.
4. **Review adversarially.** Run an adversarial review after implementation, then personally perform
   the final whole-change helicopter review: read the whole diff against the original request, check
   for regressions and loose ends, and confirm the evidence was reproduced.

### Three human checkpoints

| Checkpoint | Phase | Authorization | Authorizes |
|---|---|---|---|
| Scope | `brainstorming` | `scope_approved: true` | Preparation only |
| Implementation | `implementation` | `implementation_approved: true` or `automation.implementation: true` | Code changes |
| Delivery | `pr_submission` | `delivery: local_test \| open_pr \| auto_merge` | Local manual test, PR opening, or merge consent |

**Scope checkpoint.** Present the direction and one decision package. The user approves scope, or
sets `automation.brainstorming=true` in advance — in that automatic path the orchestrator records the
recommended/chosen directions and summary, then sets `scope_approved=true` without asking again. An
explicit "skip brainstorming" also counts: record `brainstorming.user_skipped=true`, summarize the
initial request, set `scope_approved=true`. **Scope approval covers preparation only**: feature PRDs,
PRD splitting, branch creation, tracks, and plans. It never authorizes code changes.

**Implementation checkpoint.** Preparation stops here. Present the branch and plans, then ask once
whether to implement, unless `automation.implementation=true`. Set `implementation_approved=true`
on approval. No code changes before this. `execution_mode` is resolved here, but it is not consent.
If the harness exposes a separate plan mode, present the implementation plan there; otherwise present
it in chat with the same content.

**Delivery checkpoint.** After independent verification, ask once for `local_test`, `open_pr`, or
`auto_merge`. `local_test` means the user manually tests locally first: open no PR, keep the
branch/worktree/server available, and stay pending at this checkpoint. `delivery` is set only by
explicit user instruction for the current task. **Missing delivery consent fails closed: no PR, no
merge, no publication.** Persisted consent for the same task may survive resume; never infer it from
reconstructed artifacts or copy it to another task, scope, or target. A new task/scope/target
invalidates prior merge consent.

The three authorizations are independent. Scope auto-selection never authorizes code; implementation
approval never authorizes a PR or merge; `open_pr` never authorizes a merge. Once a decision is
recorded, do not repeat it.

### Automatic preparation after scope approval

After `scope_approved=true`, preparation runs automatically — no per-document approvals and no
`/workflow next` ceremony:

- **Feature:** `brainstorming → prd_creation → prd_splitting → implementation`. Write the main PRD,
  create `<prefix>vc-<slug>` from the latest base, split per-service PRDs, create tracks, and prepare
  plans. `prd_creation` and `prd_splitting` are the only phases with `auto_advance: true`.
- **Bug/improvement:** `brainstorming → implementation` directly. No comprehensive PRDs. Create the
  branch and prepare plans at implementation entry.
- All preparation stops at the implementation checkpoint. `phase_status: completed` records that
  artifacts/checks are satisfied; it does not itself cross a checkpoint.
- Other phase transitions require their gate authorization. Exact conditions live in
  `.agentic-workflows/workflow/gates.json`; deltas between phases are described below.
- A user-requested skip of prep is recorded and only skips those artifacts. It never skips the
  implementation or delivery checkpoint.

### State discipline

- `phase_status`: `idle` (entered, not started) → `inprogress` (working) → `completed` (artifacts and
  checks satisfied). `completed` is evidence, never consent.
- Check `.workflow-state.json` before any work and update it after every state change.
- `agent_state` surfaces when the user should step in:

| Situation | `agent_state` |
|---|---|
| Plan ready, awaiting approval at a checkpoint | `needs_approval` |
| Asked a structured question | `needs_answer` |
| Stuck, free-form input needed | `needs_human` |
| Working / resumed | `null` |

Set `needs_approval` right before presenting a checkpoint approval, `needs_answer` right before a
structured question, and `needs_human` before a free-form blocker. On resume, clear both fields
first. `agent_state_reason` is non-empty whenever `agent_state` is non-null, and both are null
together (schema-enforced).

### Execution mode (not consent)

Resolve `execution_mode` after implementation approval, before code changes:

- `feature` and `improvement` → `subagents`.
- `bug` / hotfix → `main`. Hotfix is type `bug`; there is no new work type.
- A trivial or tightly coupled task may stay `main` even for a feature.
- A complex bug may make subagents the better recommendation; recommend, don't switch silently.
- A user override wins and is not re-asked. Once resolved, don't repeat the decision.

`main` is the technical lead either way: it owns planning, verification, review, and the final result.

### Subagent orchestration

Implemented via whatever subagent/delegation capability the **current harness** exposes (batched
parallel tasks, dependency edges, per-task model and reasoning effort, etc. — every harness names
these differently; don't lean on any specific tool name). If the harness has no delegation
capability, the orchestrator implements sequentially itself and says so.

Rules:

- **Parallel first when independent.** Batch independent service tasks in one delegation, not many
  sequential calls. Use dependency edges only when ordering genuinely matters.
- **Right model and effort.** Match each task to model + reasoning effort if the harness exposes a
  per-task choice: start from the advisory catalog (`workflow/model-catalog.json` — one strong pair
  per role plus alternatives), use heavy reasoning for architecture/plan/review work and cheap fast
  models for mechanical edits. Advisory only; never a mandatory pin.
- **Per-task contract.** Every delegated task gets a plan, a verification plan, the exact checks to
  run, and the evidence to return. Scale both to risk.
- **Isolated writes.** Write tasks run in their own worktree/branch and report the branch — the
  orchestrator merges.
- **Subagent scope.** Each implementation subagent covers a service end-to-end: implement, verify its
  own work (targeted lint/tests/checks), and visual-test UI work when possible. Subagents NEVER ask
  the user, open PRs, merge, authorize delivery, or advance phases.
- **Intercom (optional).** When helpful and supported, use mid-run parent-child messaging for
  steering and answers, or sibling messaging for interface coordination. The orchestrator stays
  the source of truth for decisions. Otherwise route coordination through the orchestrator;
  messaging support does not require extra ceremony.
- **Resource discipline.** Before intensive work, check disk, memory, and CPU. Keep concurrency
  bounded. Release only resources the task owns — never kill shared databases, Prefect, or other
  developers' processes.
- **Adversarial review.** After implementation, run a fresh-eyes adversarial pass (delegated if
  useful). Find what breaks, not what agrees. The orchestrator then does the final whole-change
  helicopter review personally; it is never delegated.
- **Never trust "done".** Re-run the checks, read the diff against the ticket, and visual-test
  anything claiming to render. Reproduced evidence is the standard.
- **Reconcile TODO.** After each task and again before the final report, reconcile the TODO list and
  the original request. Call out anything left open; do not bury it.

### Model recommendations (advisory)

`workflow/model-catalog.json` — installed at `.agentic-workflows/workflow/model-catalog.json` —
carries one strongly recommended model + reasoning-effort pair per role (`main`, `subagents`) plus
alternatives. It recommends; it never pins a model, switches the running main model, or writes
provider/agent configuration.

Review it once per catalog content:

1. Read the catalog and compute its SHA-256 digest. Read
   `.agentic-workflows/.model-catalog-reviewed` if it exists. Matching digest → no pending review;
   do not repeat the summary.
2. Otherwise summarize the strongly recommended pair per role, its effort and the alternatives.
   Resolve labels against models/effort the current harness/account actually make usable, not
   guessed provider IDs. Session-local unavailability is not evidence of global absence.
3. Preserve explicit user model/provider choices and the running main model. For new delegated
   tasks without an override, select an available recommended pair through the harness's per-task
   model/effort capability. Never silently switch the main model, add providers/credentials or run
   paid availability probes. If a preferred pair is unsupported, explain a supported configured
   fallback and continue; do not block otherwise workable setup. State capability limits.
4. Only after completing the review, confirm the catalog still has the digest you reviewed, then
   write that reviewed digest to `.agentic-workflows/.model-catalog-reviewed` using the available
   file-write capability. If the catalog changed during review, review the new content instead.
   Never acknowledge a newly recomputed digest whose content you have not reviewed. Interrupted,
   deferred or failed reviews leave the marker untouched.

Trigger the review at onboarding/session start when the marker is missing or does not match, and
immediately after a framework update that changes the catalog digest. The marker is derived cache —
not workflow consent, not user state, and it has no revision counter. Deleting it only re-arms the
one-time summary. The catalog is curated in the framework source and changes only through framework
releases; never add live model discovery, ranking, or a background scheduler.

### Verification and tests

- **Never add dependencies for tests.** Do not scaffold test infrastructure or add test-only packages.
- Default verification is the project's existing targeted tests, lint, type checks, and build/run
  checks, plus minimal regression checks around the changed behavior. This is allowed and expected.
- For non-trivial logic, leave one small runnable regression check; reuse existing checks where
  sufficient. Do not create a new suite or framework for ordinary verification.
- Tests and checks are evidence, not "formal verification". Never claim a mathematical or exhaustive
  proof. Say what was run, what it covered, and what remains untested.

### Parallel features (git worktrees)

Latest models work fine across git worktrees — no special tooling required.

- When the user asks for a second concurrent feature, or wants to start one mid-task, **propose
  working in parallel via git worktrees**: one dedicated worktree per affected service repo, per
  feature, so branches never collide with the active checkout.
- On approval: `git worktree add <path> -b <branch> <base>` per service, run the parallel session
  there, and keep `.workflow-state.json` keyed by slug. Cleanup with `git worktree remove` at
  completion.
- Do not propose worktrees for a single linear feature — that is just the ordinary branch flow.

### Phase machine

```
idle → brainstorming【scope】 → [features: prd_creation → prd_splitting] → implementation【implementation】
     → pr_submission【delivery】 → [pr_review?] → completion → idle
```

- `prd_creation` and `prd_splitting` are automatic preparation; feature-only.
- `pr_review` is conditional: a clean merge with zero feedback goes straight to `completion`.
- **Bug/improvement path:** `brainstorming → implementation` directly. The branch is created at
  implementation entry during preparation.
- `pr_review` may be skipped when a clean merge produced zero feedback. `local_test` stays pending at
  the delivery checkpoint until the user chooses `open_pr` or `auto_merge`; it is not completion.
- Every declared next transition has a gate; conditional transitions use the `next_gates` mapping in
  `phases.json`.
- A skip is recorded, never silent. Skips never cross the implementation or delivery checkpoint and
  never bypass merge conditions.

### Skip & ask rules

1. **Obvious answer → decide, don't ask.** If a decision is obvious from the codebase, prior PRDs,
   service conventions, or plain best practice, take the best answer, record it as a decided fact
   with one-line rationale in the summary, move on. A brainstorm with **zero questions** is valid.
2. **"No" is an acceptable answer.** Never bury a no-option; when the user says "no", stop that work
   cleanly and record it.
3. **Skip requests honored.** Only an explicit user instruction authorizes a skip. Record it
   (`brainstorming.user_skipped` or `verification["skip:<phase>"]`) and proceed. Skipping
   brainstorming counts as scope approval for the stated request. Skipping prep only skips those
   artifacts. Never skip implementation authorization, delivery consent, merge conditions,
   live-estate approval, or branch protections.
4. **NEVER modify a service base branch (develop/development/main) directly.** Work goes on `<prefix>vc-<slug>` where `<prefix>`
   is `feature/` | `fix/` | `improvement/` per `features[<slug>].type`.
5. **CHECK `.workflow-state.json` before ANY work; UPDATE it after every state change** — phase
   entry, `phase_status` flip, checkpoint authorization, transition.
6. **CHECK the git branch matches the expected branch for the phase** before doing any work.
7. **Wait at checkpoints, not on every document.** Preparation advances automatically after scope
   approval. Stop and ask once at implementation and delivery. Do not re-ask a recorded decision.

### Brainstorming phase (scope checkpoint)

1. Load the real state of every relevant service (paths, key symbols, recent changes — grep/read
   first; web search for external SDK/API/framework behavior). No code-graph MCP anywhere.
2. **Resolve ambiguity in order:** (a) codebase exploration, (b) web search, (c) your own best
   judgment when the answer is obvious or convention decides, (d) only if genuinely ambiguous →
   ask the user.
3. Decided-by-judgment items go into `brainstorming.decisions` as facts with a one-line rationale —
   NOT into `open_questions`. `open_questions` holds only true user-input decisions (often zero).
4. Write `summary`. If `automation.brainstorming=true` or the user skipped brainstorming, set
   `scope_approved=true` now after recording the chosen directions. Otherwise present the scope
   package and set `scope_approved=true` when the user agrees.
5. Flip `phase_status` to `completed`; preparation then runs automatically. Skill:
   `skills/brainstorm/SKILL.md`.

### Feature-only preparation phases

- `prd_creation`: author the main PRD from the brainstorming summary (skill `prd`). Runs
  automatically after scope approval. No per-document approval, no `/workflow next`.
- `prd_splitting`: from latest base, create `<prefix>vc-<slug>`, split the main PRD into per-service
  PRDs, create tracks, prepare plans (skill `prd-split`). Runs automatically after `prd_creation`.
  Branch creation and planning are preparation, not implementation.
- Stop at the implementation checkpoint. Do not start code.

### Implementation phase

1. **Enter and prepare.** Verify branch state. Feature path → on `<prefix>vc-<slug>` already.
   Bug/improvement path → create `<prefix>vc-<slug>` from the latest base now. Prepare per-task plans
   and verification plans. Branch and plan preparation may happen before implementation approval.
2. **Stop at the checkpoint.** If `implementation_approved` is false and
   `automation.implementation` is false, present the branch/plans and ask once. No code before.
3. **Resolve `execution_mode`** using the defaults or the user's override. Do not re-ask.
4. **Implement** using the chosen mode. Keep the track file current as tasks complete.
5. **Verify independently:** re-run targeted checks/lint/tests allowed by policy, review the diff,
   visual-test UI paths via `skills/visual-testing/SKILL.md`, run adversarial review, then the
   orchestrator's final whole-change review. Reproduce evidence; do not repeat subagent claims.
6. **Reconcile TODO and the original request.** Record plan, verification, evidence, and any open
   items in `verification`/track. Flip `phase_status` to `completed` and present the delivery
   checkpoint.

### Delivery checkpoint (`pr_submission`)

After independent verification, present the delivery choice once:

- **`local_test`** — the user manually tests locally first. Open no PR, merge nothing, publish
  nothing, and do not clean up the branch/worktree or stop the server the user is testing against.
  Stay pending at the delivery checkpoint; this is not completion. After the user confirms, ask again
  for `open_pr` or `auto_merge`. Completion still requires the intended PRs to be merged.
- **`open_pr`** — open the PR(s) and stop before merge. PR body includes the self-review and security
  audit summaries; PRD links only when a PRD exists. Feedback is handled in `pr_review`. Merging
  remains a human action.
- **`auto_merge`** — explicit per-task opt-in to open, monitor, fix, and merge. This is the only
  delivery choice that authorizes an orchestrator merge, and it is not inherited. Also requires a
  separate `live_merge_approved` for data-pipeline.

Before any PR: run the self code-review of the whole diff (a fresh-eyes reviewer may be delegated,
but the orchestrator owns the result) and the security audit. No must-fix items and no high/critical
findings may remain.

For `auto_merge`, the canonical fail-closed conditions are in
`.agentic-workflows/workflow/gates.json` → `auto_merge_policy`. In short:

- Full paginated review-thread inventory on every PR; all threads resolved, and only threads actually
  addressed. Zero threads before the expected review arrives is **not** completion.
- Required CI and the actually configured expected review are complete on the latest head; required
  approvals current; no changes requested; no conflicts.
- Self-review, security audit, adversarial review, and final whole-change review have no must-fix
  items and no high/critical findings.
- Branch protections are never bypassed, disabled, or force-pushed around.
- Every push invalidates prior head-specific proof. Re-read the latest head SHA immediately before
  merging, confirm it matches the reviewed SHA, and pin the merge command with
  `--match-head-commit <reviewed-sha>` so a concurrent push fails safely.
- Prefer native auto-merge/merge queue only if it enforces the same conditions; otherwise merge only
  after the final check immediately before the merge call.
- Bounded watch: default 30 minutes and 3 fix rounds (user may override). Persist progress, deadline,
  and rounds in the track file; the deadline and round count are preserved on resume, never reset.
  There is no background daemon. If the session cannot continue, pause and report as resumable —
  never pretend monitoring continues in the background.
- **data-pipeline is live in both `development` and `main`.** `delivery=auto_merge` alone is
  insufficient; `live_merge_approved` must be true for this task. Production promotion remains
  separate human work — no workflow path merges to production or bypasses environment promotion.

### PR review phase

Load `skills/pr-feedback/SKILL.md`: inventory every thread with pagination, classify (must-fix / nit
/ question), fix or reply with rationale, and resolve only threads actually addressed. Loop until
zero open threads. Do not re-request review unless the user says so. Any push invalidates
head-specific proof; repeat the merge checks on the latest head before merging. Track review rounds,
deadline, and fixes in the track file.

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
- On resume, verify any persisted consent belongs to the same task. Persisted explicit scope,
  implementation, delivery, or live-merge consent may survive for that task; never infer consent from
  artifacts or copy it from another task. Present any pending checkpoint afresh.

### Steps requiring sudo or external terminal

See `skills/onboard/references/external-steps.md` — tell the user what to run, block until they confirm,
verify it worked.
