# Brainstorming question patterns

Heuristics for generating good multi-choice questions during the `brainstorming` phase.

## Shape of a good question

- **Single decision per question.** If two things are tangled, split them.
- **2–4 options.** More than 4 = the agent didn't think hard enough. 1 option = not a question.
- **Mutually exclusive options.** "A or B" — never "A or A-and-B".
- **Concrete, not abstract.** "Use the existing `users` table" beats "reuse existing schema".
- **One option marked `recommended: true`.** Always exactly one. Pick the option that:
  - matches how the system already works (lower change-surface),
  - or is reversible if it turns out to be wrong,
  - or has the smallest blast radius across services.

## Categories worth asking

### Scope

- "Should this replace behavior X, coexist with it, or be mutually exclusive?"
- "Is this scoped to a single tenant, an org, or all users?"
- "Is this gated by a feature flag, role, or environment?"

### Service ownership

- "Which service owns this data — api or data-service?"
- "Should the web call api directly, or go through data-service?"

### Data model

- "New table, extend an existing one, or denormalize into JSON?"
- "Soft delete or hard delete?"
- "What's the unique key — slug, UUID, or composite?"

### Failure / empty / edge

- "What happens when the source returns zero rows — show empty state, hide the widget, or fall back?"
- "On failure, should we retry, show an error, or silently skip?"
- "What about legacy rows that predate this feature?"

### Reuse vs. build

- "There's an existing helper at `<path>` that does X — use it, fork it, or replace it?"

### UX / surface

- "Where does this surface — dashboard, settings, or its own route?"
- "Synchronous (block on result) or asynchronous (job + polling)?"

## Anti-patterns

- **Asking about implementation detail before scope.** Ask "what does this do" before "should we use Redis."
- **Leading questions.** "Should we use the right approach (X) or the wrong one (Y)?" — bias contaminates the answer.
- **False binaries.** Real-world choices often have a 3rd option ("none of the above" / "do nothing yet"). Add it when relevant.
- **Asking the user to design.** "What schema do you want?" is the agent's job, not the user's. Ask "is this user-scoped or org-scoped?" instead.

## Picking the recommended option

When in doubt:

1. The option that requires the **smallest diff** to existing code.
2. The option that's **reversible** later (start narrow, expand if needed).
3. The option that **matches the dominant pattern** already in the affected service (read `service_state_snapshots`).

If two options tie, recommend the one the user is most likely to want based on their `initial_request` phrasing.
