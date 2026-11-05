# Brainstorming question patterns

Heuristics for the scope checkpoint. The goal is not to ask more questions — it is to ask only the
ones evidence cannot settle, and to make the scope decision easy to approve.

## Shape of a good question

- **Single decision per question.** If two things are tangled, split them.
- **As many options as the decision actually has.** No floor, no ceiling. One option is not a
  question. Include every distinct viable choice, including "do nothing yet" when real.
- **Mutually exclusive options.** "A or B", never "A or A-and-B".
- **Concrete, not abstract.** "Use the existing `users` table" beats "reuse existing schema".
- **One option marked `recommended: true`.** Exactly one. Pick the option that:
  - matches how the system already works (lower change surface),
  - is reversible if wrong,
  - has the smallest blast radius across services.

## What deserves a question

Only decisions that (a) change scope, and (b) cannot be resolved from code, artifacts, web facts,
or convention. Typical:

- **Scope boundaries** — "Replace behavior X, coexist with it, or make it mutually exclusive?"
- **Ownership** — "Which service owns this data — api or data-service?"
- **Destructive changes** — "Delete the old table or keep it read-only for one release?"
- **Taste** — "Where should this surface — dashboard, settings, or its own route?"
- **Expensive reversibility** — "Change the public endpoint contract or add a new version?"
- **Live estate** — "This touches the live Prefect estate; merge and activate, or prepare only?"

## What does NOT deserve a question

- Implementation detail the plan should decide: cache choice, internal module shape, exact copy.
- Anything the codebase or an existing PRD answers.
- Anything with an obvious, low-risk, reversible default — decide it and record the rationale.
- Implementation mode, unless the user raises it: `feature`/`improvement` default to subagents,
  `bug` to main, with overrides applied at the implementation checkpoint.
- Delivery choice before verification. Ask at the delivery checkpoint, once.

## Auto-choice policy

`automation.brainstorming` (absent = `false`) allows the agent to pick the recommended scope option
and approve scope without asking. It never overrides the stop conditions:

| Situation | Action |
|---|---|
| Reversible, evidence-backed, low blast radius | Auto-pick; record `{topic, decision, rationale}` in `decisions[]` |
| Destructive: deletes data, removes behavior, rewrites history, live estate, irreversible migration | Stop and ask |
| Taste: product direction, UX surface, naming, visual choice with no evidence winner | Stop and ask |
| Expensive to reverse: public contract, schema, auth boundary, cross-service shape | Stop and ask |

Without automation, the same judgment applies, but the scope checkpoint itself still asks for
approval once questions are resolved.

## Checkpoint ask shape

Present scope, decided facts, exclusions, affected services, and the upcoming preparation. Then ask
one question: approve this scope? Options:

- **Approve scope** (`recommended: true`) — preparation starts automatically, no per-document
  approvals.
- **Adjust scope** — user states the change; fold it in and present once more.
- **Stop** — record the declined scope and do not prepare.

Keep it to one ask. If a question block is needed first, fold it into the same interaction when
possible.

## Anti-patterns

- **Question quotas** ("at least 3 challenges", "do not draft until every ambiguity is answered").
  Evidence and convention decide most things; zero questions is valid.
- **Relentless clarification** after the user already approved or preauthorized a direction.
- **Per-document approval** — asking the user to sign off on the PRD or each service PRD. Those are
  preparation artifacts; the next checkpoint is implementation.
- **Asking about implementation detail before scope.** Ask "what does this do" before "should we
  use Redis".
- **Leading questions.** "The right approach (X) or the wrong one (Y)?" — bias contaminates the
  answer.
- **False binaries.** Add the real third option when one exists.
- **Asking the user to design.** "What schema do you want?" is the agent's job. Ask "is this
  user-scoped or org-scoped?" instead.
- **Re-asking an approved checkpoint.** Check the recorded field first; if it is true, continue.

## Picking the recommended option

When in doubt:

1. The option with the **smallest diff** to existing code.
2. The option that is **reversible** later (start narrow, expand if needed).
3. The option that **matches the dominant pattern** in the affected service (read
   `service_state_snapshots`).

If two options tie, recommend the one closest to the user's `initial_request` phrasing.
