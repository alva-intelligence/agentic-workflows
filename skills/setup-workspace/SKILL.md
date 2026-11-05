---
name: setup-workspace
description: Interactive wizard to create a new agentic workspace — walks through project definition, services, delegation defaults, skills, MCPs, and generates all configuration files from the agentic-workflows framework.
---

# Setup New Agentic Workspace

This skill guides you through creating a brand new agentic workspace from the `agentic-workflows` framework. It asks questions about your project, then generates the configuration files — fragments, skills, schemas, templates, and manifest.

## Interaction Model — READ THIS FIRST

> **1. Use the current harness's planning/research mode when it has one.** If it has none, announce an explicit research phase and stay read-only until Step 5 is answered.
>
> **2. Steps 0–5 are interactive.** Present each step's questions, wait for answers. Do NOT assume or skip.
>
> **3. After Step 5 — leave the planning/research mode** and generate files.
>
> **4. Create a todo checklist** based on user's answers. Only generate files relevant to what they selected.
>
> **5. After each generation step,** briefly summarize what was created before moving to the next.

## Asking the User (MANDATORY)

Use the structured ask/question capability the current harness exposes and block until the user responds. If the harness has no such capability, print one compact question block (options plus one recommendation) and wait for the reply.

**NEVER** bury a question in narrative or drip-feed one question per turn.

## Before Starting

Read the existing agentic-workflows repo to understand the framework structure:

1. Read `manifest.json` to see all files and their install paths
2. Read `agents/fragments/` to understand fragment structure
3. Read `workflow/phases.json`, `workflow/gates.json`, `workflow/state-schema.json`
4. Read `skills/onboard/SKILL.md` as a reference for how skills are structured
5. Read `agents/fragments/workflow-rules.core.md` — the orchestrator + subagent delegation model

This gives you the full template to adapt from.

## Step 0: Project Identity — **STOP, ask**

Use the ask tool:

> "Let's set up your new agentic workspace. First, some basics:"

### 0.1 Project name

> "What's your project name? (lowercase, used for directory names and prefixes)"
> - Text input (e.g., `myapp`, `acme-platform`, `dataflow`)

### 0.2 Description

> "One-line description of what this project does:"
> - Text input

### 0.3 Workspace style

> "How is your project structured?"
> - **Multi-repo orchestrated** — Multiple service repos in one workspace directory (like frndOS: `api/`, `web/`, etc.)
> - **Mono-repo** — Single git repo with all services
> - **Single service** — Just one repo, one service

Record all answers. The workspace style affects nearly every subsequent step.

## Step 1: Services — **STOP, ask**

### 1.1 Define services

> "List your services. For each one, I need:"
>
> | Field | Example |
> |-------|---------|
> | Name | `api` |
> | Directory | `api/` |
> | Repository | `org/repo-name` |
> | Stack | `Express, Node.js, PostgreSQL` |
> | Default branch | `main` |
> | Dev server port | `3000` |
> | Start command | `npm run dev` |
> | Health check URL | `http://localhost:3000/health` |
> | Healthy condition | `200 OK` |
> | Env file path | `api/.env` |
> | Env file contact | `alice` |
>
> "How many services do you have? List them one by one, or paste a table."

**STOP AND WAIT.** Let the user define all services. Ask follow-up questions if anything is ambiguous.

### 1.2 Service owners

> "Who owns each service? (for PR reviews and .env contacts)"

Record the full service registry.

## Step 2: Workflow Phases — **STOP, ask**

Present the default phase machine and its three human checkpoints:

> "The default workflow keeps these phase IDs:"
> ```
> idle → brainstorming → prd_creation → prd_splitting →
> implementation → pr_submission → [pr_review?] → completion → idle
> ```
> `pr_review` is conditional — skipped when the PR merges cleanly with no reviewer feedback.
>
> "Phases are bookkeeping. Only three moments need a person: **Scope** (end of brainstorming), **Implementation** (after automatic PRD/branch/plan preparation), and **Delivery** (after verification). Between them, preparation runs automatically — no per-document approvals and no manual phase advance."
>
> "Which phase set do you need?"
> - **All 8** — Full workflow with brainstorming, PRD preparation, implementation, PR submission + optional review
> - **No PRD splitting** — Single service, no need to split PRDs
> - **Minimal** — Just: idle → implementation → pr_submission → completion
> - **Custom** — I'll tell you which to keep/add

If user picks **Custom**, ask them to list:
- Phases to **remove** from the default 8
- Phases to **add** (describe what they do and where they fit)

## Step 3: Delegation — no agent roster — **inform**

**No agent roster and no generated agent files.** The running agent is the orchestrator: it plans,
delegates implementation to subagents when useful, verifies every claim, and keeps the final
verdict. The current harness supplies whatever delegation/intercom capability it has; no model,
tool, or per-editor agent definition is written into the workspace. The shipped catalog
(`workflow/model-catalog.json`) carries advisory recommendations only — never generated model
definitions.

### 3.1 Execution defaults

> Execute `feature` and `improvement` work with subagents by default, and `bug`/`hotfix` work in
> the main agent. Trivial or tightly coupled work may stay in the main agent; a complex bug may use
> subagents. The user can override at the implementation checkpoint; do not ask again once chosen.
>
> No model is pinned or generated, and none is switched automatically. Start from the advisory
> catalog (`workflow/model-catalog.json`): one strongly recommended model + effort pair per role,
> plus alternatives. Match the current harness/account's usable models and effort levels, keep any
> explicit user choices, and continue on a supported fallback when the strong pick is unavailable.

### 3.2 Advisory model catalog

> The workflow ships an advisory model catalog. At onboarding/session start, and right after an
> update changes it, the agent summarizes its recommendations once and checks them against the
> models you can actually use here. It never changes your model/provider setup, adds credentials,
> or runs paid checks. A completed review is cached by content digest in
> `.agentic-workflows/.model-catalog-reviewed`; an unchanged catalog is not summarized again, and
> an interrupted review stays pending.
>
> Canonical procedure: `workflow-rules.core.md` → "Model recommendations (advisory)".

### 3.3 Editor support

> "Any editor/CLI targets?" (skills are shared; no per-editor agent files are generated)
> - Text input, free-form

## Step 4: Skills & MCPs — **STOP, ask**

### 4.1 Built-in skills

> "Which skills do you need?"
> - `/onboard` — Interactive workspace setup wizard
> - `/workflow` — Feature state machine management
> - `/brainstorm` — Evidence-first brainstorming plus the scope checkpoint
> - `/prd` — PRD creation helper
> - `/prd-split` — PRD splitter (also creates the feature branch)
> - `/pr-feedback` — address + resolve PR review threads
> - `/visual-testing` — browser-use visual validation for UI work
> - Custom: describe any additional skills

### 4.2 Community skills

> "Any community skills from [skills.sh](https://skills.sh)?"
> Examples:
> - `anthropics/skills@frontend-design`
> - `vercel-labs/next-skills@next-best-practices`
> - `busirocket/agents-skills@busirocket-tailwindcss-v4`
>
> "List any you want, or skip."

### 4.3 MCP servers

> "Which MCP servers do you need?"
>
> | MCP | Package | What it does | Needs credentials? |
> |-----|---------|-------------|-------------------|
> | Context7 | `@upstash/context7-mcp` | Library docs lookup | No |
> | GitHub | `@modelcontextprotocol/server-github` | PR/issue management | Yes (PAT) |
> | Lark CLI | official Lark CLI | Read pasted Lark doc links (read-only) | Yes (account auth — CLI only, never an MCP) |
> | Figma | `@anthropics/figma-mcp` | Design specs from Figma | Yes (PAT) |
>
> "List the ones you need. You can also add custom MCPs."

## Step 5: Dev Environment — **STOP, ask**

### 5.1 Toolchain

Tools are installed directly on the developer machine (Homebrew on macOS) — there is no Nix layer.

> "List the languages, tools, and databases you need, with pinned versions. Examples:"
> - Languages: `python@3.12`, `node@22`, `php@8.5`, `go`
> - Databases: `postgresql@18`, `redis`, `mongodb-community`
> - Tools: `curl`, `gh`, `git`, `jq`

These become the install/verify tables in the generated `onboard/SKILL.md` Step 2.

### 5.2 Branch conventions

> "What branch naming conventions do you use?"
> - Feature branches: (e.g., `feature/vc-<slug>`, `feat/<name>`)
> - PR target branch: (e.g., `develop`, `main`)
> - Commit format: (e.g., `<type>(<scope>): <description>`)

### 5.3 Any other conventions?

> "Anything else I should know? Review process, team size, special rules, etc."

---

> **Leave the planning/research mode now.** The user has answered all questions.
>
> **Create a todo checklist now.** Based on all answers, list every file that needs to be created or modified.

---

## Step 6: Create a Branch

```bash
git checkout -b setup/<project-name>
```

## Step 7: Generate Fragments

Based on user's answers, create/update files in `agents/fragments/`:

1. **`service-registry.md`** — Replace with user's services table, start commands, health checks, env files
2. **`session-protocol.md`** — Adapt health checks and service detection to match user's services
3. **`workflow-rules.md`** — Update phase list, branch conventions, gate conditions, and the three checkpoint guards (scope, implementation, delivery) with automatic preparation between them. Remove sections for phases the user dropped. Add sections for custom phases.
4. **`git-conventions.md`** — Update branch naming, commit format, PR conventions, default branches per service
5. **`prd-conventions.md`** — Keep or adapt based on whether PRD phases are included
6. **`track-conventions.md`** — Keep or adapt based on whether track files are needed

## Step 8: Generate Workflow Schema

Update files in `workflow/`:

1. **`phases.json`** — Only include phases the user selected. Add custom phases.
2. **`gates.json`** — Define gate conditions for each phase transition. Remove gates for dropped phases. Add gates for custom phases. Keep the three checkpoint guards explicit: scope before preparation, implementation before code changes, delivery before PR/merge work.
3. **`state-schema.json`** — Adapt the feature schema to the phases and service structure. Always include `phase_status` with **all three values** (`idle` | `inprogress` | `completed`), and the required `agent_state` / `agent_state_reason` pair (both null, or reason non-empty). Include the optional checkpoint fields with safe defaults: `scope_approved` (false), `automation` (`{brainstorming:false, implementation:false}`), `execution_mode` (null), `implementation_approved` (false), `delivery` (null), `live_merge_approved` (false). Existing state files without these fields must remain valid.
4. **`model-catalog.json`** — Copy the advisory catalog unchanged (labels + effort only; no provider or API identifiers). Give it a manifest entry with `type: workflow` and `install_to: .agentic-workflows/workflow/model-catalog.json`. Do not generate per-editor model definitions or write the `.model-catalog-reviewed` marker into the repo.

## Step 9: (was Agent Definitions — no agent files anymore)

The orchestrator model needs **no agent files**: the running agent drives all phases, delegation
happens via the harness's subagent capability, and per-task models/effort are chosen at delegation
time (see `workflow-rules.core.md`). The only model guidance is the advisory catalog from Step 8 —
no pins and no generated preferences; skip to Step 10.

## Step 10: Generate Skills

For each skill the user selected, create/update files in `skills/`:

1. **`workflow/SKILL.md`** — Adapt commands to match user's phases and services
2. **`onboard/SKILL.md`** — Rewrite for user's services, stack, tools, MCPs. Include their specific install commands, env file contacts, and health checks.
3. **Other skills** — Adapt or create as needed

## Step 11: Generate Config Files

1. **`onboard/SKILL.md` Step 2** — Build the install/verify tables from the user's pinned package list. Include version checks and health checks for their services.
2. **`AGENTS.md.template`** — Update fragment includes to match what was generated. Remove includes for dropped fragments.

## Step 12: Generate Templates

Update files in `templates/`:

1. **`prd/main-prd.template.md`** — Adapt frontmatter fields to user's services
2. **`prd/service-prd.template.md`** — Same
3. **`tracks/feature.track.template.md`** — Adapt to user's services and phases; keep the plan/verification/evidence, checkpoint, delivery, and bounded review-watch sections
4. **`pr/feature-pr.template.md`** — Adapt to user's PR conventions

## Step 13: Update Manifest

1. Compute SHA256 hashes for ALL generated files
2. Update `manifest.json` with correct hashes and install paths
3. Bump version in `VERSION`

## Step 14: Generate Scripts

1. **`scripts/generate-agents.sh`** — Adapt to assemble AGENTS.md from the user's fragments
2. **`scripts/update-check.sh`** — Should work as-is (generic)

## Step 15: Run Generate & Verify

```bash
bash scripts/generate-agents.sh
```

Verify:
- All files in `manifest.json` exist and hashes match
- `phases.json` phases match `state-schema.json` enum
- `gates.json` has entries for all phase transitions
- Checkpoint fields are present or optional-with-safe-defaults; no agent roster or routing table is generated
- `workflow/model-catalog.json` parses, keeps one strongly recommended model + effort pair per role, and pins nothing
- No references to `frndos` remain (replaced with user's project name)

## Step 16: Summary

Present the user with:

```
Workspace "<project-name>" generated on branch setup/<project-name>.

Files created/modified:
  agents/fragments/     — <count> fragments
  skills/               — <count> skills
  workflow/             — phases, gates, state schema
  templates/            — <count> templates
  manifest.json         — file registry with hashes

To use this workspace:
  1. Create a new directory for your project
  2. Run the bootstrap script to install files
  3. Open an agent session and run /onboard

Branch: setup/<project-name>
```
