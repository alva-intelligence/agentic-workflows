---
name: brainstorm
description: Run the brainstorming phase — resolve scope from real service state, decide the obvious, and take the scope checkpoint
---

# Brainstorming

Sharpens scope and takes the **scope checkpoint**. The orchestrator loads the latest state of every
relevant service, resolves every ambiguity it can from evidence and best judgment, records those as
decided facts, and asks the user only for decisions that genuinely need them. **Zero questions is a
valid outcome.**

Scope approval is the only human gate in this phase. Once approved, preparation continues
automatically: `prd_creation` and `prd_splitting` for features (main PRD, branch, service PRDs,
tracks with plans), or branch and track preparation for bugs/improvements. No per-document
approvals and no `/workflow next` ceremony.

**Read `references/question-patterns.md`** for question shape, auto-choice policy, and pitfalls.

## Inputs (from `.workflow-state.json`)

- `active_feature`, `worker`
- `features[active_feature].type` — feature | bug | improvement (a hotfix is a bug)
- `features[active_feature].initial_request` — raw user intake
- `features[active_feature].scope_approved` — absent means `false`
- `features[active_feature].automation.brainstorming` — absent means `false`
- Optional: `delivery`, `live_merge_approved` — only if the user already gave an explicit instruction

## Outputs (back to `.workflow-state.json`)

- `brainstorming.service_state_snapshots` — per-service short snapshot
- `brainstorming.questions[]` — `{ id, prompt, options[], answer }` — only questions actually asked
- `brainstorming.decisions[]` — `{ topic, decision, rationale }` — answers decided by the agent
- `brainstorming.summary` — 3–8 sentence direction
- `brainstorming.completed_at`
- `scope_approved` — `true` only after the scope checkpoint is passed
- `features[active_feature].phase_status = "completed"` (`"inprogress"` at start)
- Next: automatic preparation, not a user-triggered phase advance

## Process

### Step 0: Activate phase

Flip `features[active_feature].phase_status` to `"inprogress"` in `.workflow-state.json`.

Read `scope_approved` (absent = `false`). If it is already `true`, do not re-open scope; continue
preparation at the current phase.

If the user asked to **skip** brainstorming: record `brainstorming.user_skipped = true`, add a
`brainstorming.decisions[]` entry `{topic: "brainstorming", decision: "user_skipped", rationale:
"<their wording>"}`. A skip waives the artifact, not the scope checkpoint: the summary still gets
written and scope still needs approval (unless `automation.brainstorming` is true and no stop
condition remains).

### Step 1: Load latest service state

Identify candidate services from `initial_request`. For each, build a short snapshot with
grep/read of the actual code (paths, key symbols, recent behavior). No code-graph MCP.

For external behavior (third-party SDKs, APIs, frameworks) where training data may be stale, use
web search/fetch. Save under `brainstorming.external_state_snapshots[<vendor>]` with URL + fact.

Also read existing PRDs, tracks, and recent commits that could overlap with this work. Note
conflicts explicitly.

### Step 2: Resolve ambiguity — evidence first, ask last

Walk every branch of the decision tree implied by `initial_request`. Resolve each one in order:

1. **Codebase and artifacts first.** If the code, PRDs, tracks, or service state answers it, use
   that.
2. **Web search second.** External vendor/SDK/framework behavior. Cite the URL.
3. **Obvious answer → decide it yourself.** If the answer is obvious from convention, existing
   system behavior, or plain best practice, pick the best option and record a decision:
   `{ topic, decision, rationale }`. Do not ask.
4. **Ask the user last.** Only genuinely ambiguous, taste, destructive, or expensive-to-reverse
   calls become questions. No quotas, no minimum count.

Record every assumed answer as a decision, including the rationale. Never leave an assumed answer
implicit in the summary; PRD and implementation both read `decisions[]`.

### Step 3: Scope auto-choice policy

`automation.brainstorming` controls how much of the scope checkpoint may pass without the user.
Read it as `false` when absent.

- **Automation off (default):** the agent still decides everything evidence can settle. Only the
  surviving questions go to the user, in one structured ask. After that, the scope checkpoint asks
  for approval of the resulting scope.
- **Automation on:** the agent may also auto-pick the recommended option for unresolved scope
  choices and auto-approve scope when the resulting scope is clear. Record each auto-choice in
  `decisions[]` with `rationale`.
- **Stop conditions always win.** Even with automation on, stop and ask when an unresolved scope
  change is:
  - **destructive** — deletes data, removes existing behavior, rewrites history, changes a live
    estate, or has an irreversible migration;
  - **taste-based** — product direction, UX surface, naming, or visual choice with no clear
    evidence-backed winner;
  - **expensive to reverse** — a public contract, schema, auth boundary, or cross-service shape
    that is costly to undo.

Do not ask about implementation details that belong to the plan. Ask about scope: what is in,
what is out, what behavior changes, which service owns it, and what must not break.

### Step 4: Produce the unresolved questions (often zero)

Only what survived Steps 2–3 becomes `questions[]`: `{id, topic, options[],
recommended_label, rationale}`, `recommended: true` on exactly one option. Everything else is
already a fact in `decisions[]` or `summary`.

Fold questions into ONE structured ask (up to 4 questions in one call). If the user answers in free
text, record the answer. If the user says **"no"** or declines a direction: stop that branch
cleanly and record the answer.

### Step 5: Write the summary

3–8 sentences. Facts resolved via codebase/web, the decisions taken by judgment (one line of
rationale each), what remains open, and the direction. Save to `brainstorming.summary`; set
`completed_at`.

### Step 6: Take the scope checkpoint

Present one compact scope package:

- The scope in plain language: included, excluded, affected services, behavior changes.
- Decided facts and auto-choices, with their rationale.
- Any residual risk or explicit "not doing".
- The preparation that will run next (PRD + split + branch + plans for features; branch + plans
  for bugs/improvements).
- The default execution mode (`subagents` for feature/improvement, `main` for bug) and that the
  delivery choice comes only after verification.

Then:

- If `scope_approved` is already true → skip the ask.
- Else if `automation.brainstorming` is true and no stop condition remains → set
  `scope_approved = true`, record the auto-approval and its basis in `decisions[]`, clear
  `agent_state` / `agent_state_reason`, and continue.
- Else set `agent_state = "needs_approval"` with a non-empty reason, ask once, and wait.

On approval: set `scope_approved = true`, clear the attention pair, set `phase_status =
"completed"`, save. If the user declines, record the declined scope and stop; do not prepare.

**Approval wording matters.** "Skip brainstorming", "looks interesting", or silence is not scope
approval. An explicit "yes, that scope", "go ahead with this", or an equivalent instruction is.
If the user's original request already explicitly approved this exact scope, record that wording
and do not re-ask.

### Step 7: Continue automatically to preparation

Do not ask whether to advance and do not tell the user to run `/workflow next`.

- **Feature:** transition to `prd_creation` and run the `prd` skill. When the PRD is written,
  continue to `prd_splitting` and the `prd-split` skill. Stop at the implementation checkpoint.
- **Bug / improvement:** transition to `implementation`. Run its preparation (branch, track, task
  plans, verification plans) and stop at the implementation checkpoint.

The implementation checkpoint is where the user next decides anything, unless
`automation.implementation` is already true or an implementation preauthorization was recorded.

## When to use

- New feature/bug/improvement filed via `/workflow start <slug>`.
- Resuming a feature still in `brainstorming`.

## When NOT to use

- Scope is already approved for this feature — continue preparation; do not re-open it.
- The user already supplied a complete PRD: validate it against current service state (one pass),
  record the scope decision, and continue preparation. Do not run a PRD-authoring loop.
