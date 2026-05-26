---
name: brainstorm
description: Run the brainstorming phase — multi-choice questioning grounded in latest service state
---

# Brainstorming

Sharpens scope before a PRD is written. The agent loads the latest state of every relevant service, generates a small set of pointed multi-choice questions, asks the user, and writes a summary that feeds the PRD phase.

**Read `references/question-patterns.md`** for heuristics on what to ask and how to pick the recommended option.

## Inputs (from `.workflow-state.json`)

- `active_feature`, `worker`
- `features[active_feature].type` — feature | bug | improvement
- `features[active_feature].initial_request` — raw user intake

## Outputs (back to `.workflow-state.json`)

- `features[active_feature].brainstorming.service_state_snapshots` — per-service short snapshot
- `features[active_feature].brainstorming.questions[]` — `{ id, prompt, options[], answer }`
- `features[active_feature].brainstorming.summary` — 3–8 sentence direction
- `features[active_feature].brainstorming.completed_at`
- `features[active_feature].phase_status = "completed"` (set to `"inprogress"` at start, then `"completed"` when done; do NOT auto-advance)

## Process

### Step 0: Activate phase

Flip `features[active_feature].phase_status` to `"inprogress"` in `.workflow-state.json`.

### Step 1: Load latest service state

Identify candidate services from `initial_request`. For each, build a short snapshot using the code-graph MCP tools first, falling back to grep/read when the graph doesn't cover what you need.

For external behavior (third-party SDKs, APIs, frameworks) where your training data may be stale, use web search/fetch to pull latest docs/changelogs. Save under `brainstorming.external_state_snapshots[<vendor>]` with URL + fact.

Save each service snapshot to `brainstorming.service_state_snapshots[<service>]`.

### Step 2: Grill protocol — walk every branch of the decision tree

Interview the design relentlessly until shared understanding is reached. Walk every branch implied by `initial_request`. Stop only when no ambiguity remains, not at an arbitrary question count.

**Resolve every ambiguity in this priority order:**

1. **Codebase first.** If a question can be answered by reading code, PRDs, or querying the code-graph MCP, do that. Do NOT generate a user-facing question for something the codebase already answers.
2. **Web search second.** For external SDK/API/framework/vendor behavior where training data may be stale, use web search/fetch. Cite the URL.
3. **Multi-choice question last.** Only when neither codebase nor web can resolve — genuine product/design judgment calls.

After every resolved branch, walk the downstream branches it opens. Drop branches a resolution makes moot; regenerate ones it changes.

**No quotas.** No min/max question count. No min/max options per question. Include every viable distinct option. Each option has `label`, `value`, optional `description`, and `recommended` (boolean). **Exactly one option per question** has `recommended: true` — safer / lower-friction / aligned with existing system. Cite codebase paths or URLs inline in option `description` whenever the recommendation derives from one.

Use `references/question-patterns.md` for shape and pitfalls.

### Step 3: Produce final unresolved questions list

Output ONLY questions you could not resolve via codebase exploration or web search. Drop any question that got answered along the way — that fact belongs in `summary`, not `open_questions`.

Do NOT call the ask tool. Do NOT self-resolve under assumed answers. No `assumed_answer` field. Orchestra asks user one at a time.

For each unresolved question, record `{id, topic, options[], recommended_label, rationale}`. Exactly one option has `recommended: true`; copy its label into `recommended_label`.

### Step 4: Write the summary

3–8 sentences. Capture facts resolved via codebase/web exploration and the direction they suggest. Save to `brainstorming.summary`. Set `brainstorming.completed_at`.

### Step 5: Mark phase completed and stop

Flip `phase_status` to `"completed"`. Do NOT auto-advance. Tell the user: "Brainstorming complete. Run `/workflow next` to advance to PRD creation."

## When to use

- New feature/bug/improvement filed via `/workflow start <slug>`. Orchestra advances `idle → brainstorming` and routes here.
- Resuming a feature that's still in `brainstorming` phase.

## When NOT to use

- The user has already supplied a complete PRD. In that case, answer 1 confirmation question (e.g., "Do you want me to validate this PRD against current service state, or just register it?") and write a one-line summary citing the user's PRD as the source.
