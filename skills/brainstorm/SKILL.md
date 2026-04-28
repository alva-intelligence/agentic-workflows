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
- `features[active_feature].phase_status = "completed"` (do NOT auto-advance)

## Process

### Step 1: Load latest service state

Identify candidate services from `initial_request`. For each, build a short snapshot using the code-graph MCP tools first, falling back to grep/read when the graph doesn't cover what you need.

Save each snapshot to `brainstorming.service_state_snapshots[<service>]`.

### Step 2: Generate questions

3–6 questions, 2–4 options each. Each option has `label`, `value`, optional `description`, and `recommended` (boolean). **Exactly one option per question** has `recommended: true`. Pick the option that's safer / lower-friction / better aligned with how the system already works.

Use `references/question-patterns.md` for shape and pitfalls.

### Step 3: Ask the user

For each question, use the ask tool. Recommended option first, labeled `(Recommended)`. Record the answer in `brainstorming.questions[i].answer`. If "Other", store the user's free text. If an answer changes downstream context, regenerate the remaining questions.

### Step 4: Write the summary

3–8 sentences. Capture chosen direction, key trade-offs accepted, open follow-ups for PRD phase. Save to `brainstorming.summary`. Set `brainstorming.completed_at`.

### Step 5: Mark phase completed and stop

Flip `phase_status` to `"completed"`. Do NOT auto-advance. Tell the user: "Brainstorming complete. Run `/workflow next` to advance to PRD creation."

## When to use

- New feature/bug/improvement filed via `/workflow start <slug>`. Orchestra advances `idle → brainstorming` and routes here.
- Resuming a feature that's still in `brainstorming` phase.

## When NOT to use

- The user has already supplied a complete PRD. In that case, answer 1 confirmation question (e.g., "Do you want me to validate this PRD against current service state, or just register it?") and write a one-line summary citing the user's PRD as the source.
