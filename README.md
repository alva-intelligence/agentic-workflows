# frndOS Agentic Workflows

> **Maintainer:** Alva Intelligence Engineering

---

## For LLM Agents — Read This First

> **If you are an LLM agent and a user has pointed you at this repository, follow the instructions below.**
>
> **CRITICAL: Do NOT clone this repository.** This repo is an instruction set, not a project to clone. The workspace directory should remain a plain folder (NOT a git repo). You install files by running the bootstrap script below, which downloads only the needed files. NEVER run `git clone` with this repo URL into the user's workspace.

### Step 1: Welcome the user

Display this welcome message:

```
Welcome to frndOS Agentic Workflows!

frndOS is a multi-service platform built by Alva Intelligence. This system sets up
your development workspace and guides you through a structured feature development
workflow — from PRD creation to wireframing, implementation, and PR submission.

What gets installed:
  - 10 phase-scoped AI agents (orchestra, prd, wireframe, splitter, implement, engineer, architect, pr, track)
  - 8 skills (/onboard, /workflow, /workflow-update, /prd, /prd-split, /wireframe, /jj-workflow, /setup-workspace)
  - An 11-phase workflow state machine with gate enforcement
  - Agent Teams support — parallel per-service engineers + architect (Claude Code)
  - JJ workspace support — parallel features in isolated directories (Claude Code, Amp)
  - Auto-updating instruction system (stays in sync with team changes)
  - Templates for PRDs, service PRDs, track files, and PRs

Supported tools: Claude Code, Cursor, OpenCode, Amp (and any tool supporting SKILL.md)
```

### Step 2: Ask for confirmation

Use your **ask tool** (Claude Code: `AskUserQuestion`, Cursor: ask tool, OpenCode: question tool; Amp has no dedicated ask tool — ask as plain text and wait):

> "Would you like to set up frndOS and start the agentic workflow?"
> - Yes, set it up
> - No, not now

**Do NOT proceed without explicit confirmation.** The ask tool blocks until the user responds.

### Step 3: If yes — run the bootstrap (DO NOT CLONE)

**Do NOT run `git clone`.** Instead, run the bootstrap script which downloads individual files into the current directory:

```bash
curl -sL "https://raw.githubusercontent.com/alva-intelligence/agentic-workflows/main/scripts/update-check.sh" \
  -o /tmp/aw-update-check.sh && bash /tmp/aw-update-check.sh --bootstrap
```

This downloads agents, skills, fragments, templates, and workflow configs into `.agentic-workflows/`, `.agents/`, and generates `AGENTS.md`. The workspace directory stays a plain folder — NOT a git repo.

### Step 4: After bootstrap — start onboarding

1. Read the generated `AGENTS.md` file in the workspace root
2. Follow the **Session Start Protocol** — it detects this is a fresh workspace
3. Use your **ask tool** to ask: "Would you like to start onboarding now?"
4. If yes: Read `.agents/skills/onboard/SKILL.md` and execute the onboarding directly in this session
5. Onboarding walks through: GitHub access, service selection, cloning, dependencies, .env files, database, editor config, and MCP setup

### Flow summary

```
User points agent at this repo
  → Agent reads README.md (this file)
  → Agent shows welcome message
  → Agent asks: "Ready to set up?" (yes/no)
  → If yes: bootstrap → AGENTS.md → asks "Start onboarding now?"
  → If yes: reads SKILL.md directly → runs onboarding in same session
  → After onboarding: /workflow start <feature-slug>
```

---

## For Humans — Repository Reference

This repo is the single source of truth for frndOS AI agent instructions. It is NOT cloned into workspaces — instead, individual files are downloaded and cached locally via the auto-update mechanism.

### See it work

A complete feature lifecycle — from idea to merged PRs. The agent handles everything; you steer.

```
You:    /workflow start brand-health-dashboard
Agent:  Feature "brand-health-dashboard" started. Phase: prd_creation.
        [delegates to frndos-prd]

You:    Here's the Lark doc: https://lark.com/doc/...
        The dashboard should show brand sentiment over time,
        top mentions, and alert thresholds.
Agent:  [reads Lark doc via MCP, asks clarifying questions]
        [drafts PRD with objectives, user stories, acceptance criteria]
        [asks you to review before saving]
You:    Looks good, but add a comparison view for multiple brands.
Agent:  [updates PRD, saves to docs/prd/brand-health-dashboard.md]
        PRD created. → Phase: wireframe.

You:    /workflow next
Agent:  [delegates to frndos-wireframe]
        [reads PRD, scans existing frndos components, studies previous wireframes]
        [presents plan: main dashboard page + detail sub-page + comparison view]
You:    Go ahead.
Agent:  [builds production-quality static frontend — real components, real interactions]
        [creates wireframes/brand-health-dashboard/dashboard/ with page.tsx,
         components/, [brandId]/page.tsx, compare/page.tsx, metadata.json]
        [commits on wireframe/claude/vc-brand-health-dashboard branch]
        Done. → Phase: wireframe_pr.

Agent:  [delegates to frndos-pr]
        [creates PR targeting develop, fills template, tags FE owners]
        PR: github.com/alva-intelligence/frnd-web/pull/87
        → Phase: wireframe_review. Waiting for FE owners + Jeff approval.

You:    Jeff approved. FE owners merged.
Agent:  [verifies PR merged on GitHub]
        → Phase: branch_creation.
        [checkouts develop, verifies wireframe on develop, creates feature branch]
        Branch: feature/claude/vc-brand-health-dashboard
        → Phase: prd_splitting.

Agent:  [delegates to frndos-splitter]
        [reads main PRD, determines affected services: api + web]
        [generates api/docs/prd/brand-health-dashboard.md — endpoints, migrations, models]
        [generates web/docs/prd/brand-health-dashboard.md — pages, state, API integration]
        Service PRDs created. → Phase: implementation.
```

**From here, the path splits based on your session mode:**

```
━━━ Agent Session (sequential) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Agent:  [delegates to frndos-implement]
        [reads both service PRDs, presents implementation plan]
You:    Approved.
Agent:  [implements API: migrations, models, controllers, tests]
        [implements Web: wires wireframe to real API, state management, error handling]
        [self-reviews, commits per task]
        Implementation complete. → Phase: pr_submission.

Agent:  [delegates to frndos-pr]
        [creates PR per service targeting develop/development]
        API PR: github.com/.../pull/201
        Web PR: github.com/.../pull/88
        → Phase: pr_review.

You:    API reviewer requested changes on the pagination endpoint.
Agent:  [reads feedback, fixes, pushes, comments on PR]
        Changes addressed. Waiting for re-review.
        [PR merged] → Phase: completion.

━━━ Team Session (parallel, experimental) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Agent:  [creates agent team: architect + api-engineer + web-engineer]
        [creates shared task list with per-service chains]
        [engineers present plans in read-only mode → you approve each]

        api-engineer:  [implements API service, self-reviews]
                       → messages lead: "Done. Ready for architect review."
        web-engineer:  [implements Web service, self-reviews]
                       → messages lead: "Done. Ready for architect review."

Agent:  [messages architect to review api-engineer's work]
Architect: [reviews cross-service integration]
           → "API contracts match frontend calls. Approved."
Agent:  [messages api-engineer: "Create your PR."]
        api-engineer: PR: github.com/.../pull/201

Agent:  [messages architect to review web-engineer's work]
Architect: → "Response shape mismatch on /api/brands/{id}/mentions"
Agent:  [relays to web-engineer, who fixes and re-requests review]
Architect: → "Fixed. Approved."
        web-engineer: PR: github.com/.../pull/88

Agent:  [all PRs merged → shuts down teammates → cleans up team]
        → Phase: completion.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

```
Agent:  [delegates to frndos-track]
        [updates track file: all tasks complete, PRs merged]
        [marks feature complete in .workflow-state.json]
        Feature "brand-health-dashboard" complete!

You:    /workflow start next-feature...
```

You described a dashboard. The agent wrote the PRD, built a polished static frontend,
split the work into service PRDs, implemented across services, handled code review,
and shipped merged PRs. You approved plans and steered — the agents did the rest.

### Workflow State Machine

11 phases with gate enforcement — each phase has a dedicated agent and model assignment.

![Workflow State Machine](./docs/workflow-state-machine.svg)

### Agent Architecture

Phase-scoped agents with auto-delegation — orchestra routes, sub-agents do the work.

![Agent Architecture](./docs/agent-architecture.svg)

### Agent Teams (Parallel Implementation)

When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set (configured via `.claude/settings.json` during onboarding), the `implementation` phase uses Claude Code's Agent Teams API instead of a single sequential agent:

| Role | Agent | Count | Description |
|------|-------|-------|-------------|
| **Lead** | frndos-orchestra | 1 | Creates the team, approves plans, coordinates reviews, tracks PRs |
| **Architect** | frndos-architect | 1 | Cross-service integration reviewer (does NOT write code) |
| **Engineer** | frndos-engineer | 1 per service | Implements, self-reviews, and creates PR for their assigned service |

**How it works:**
- Lead creates the team via natural language (not `Agent()` tool calls)
- Each teammate is a persistent session with its own context
- Communication happens via **mailbox** (`message` for 1:1, `broadcast` for all)
- Engineers are spawned with **plan approval required** — they're in read-only mode until the lead approves
- Shared task list tracks per-service chains: `plan → implement → self-review → architect-review → pr`
- When all PRs are merged, lead shuts down teammates and cleans up the team

**Sequential fallback:** Cursor, OpenCode, Amp, or when the env var is unset — uses `frndos-implement` → `frndos-pr` (unchanged). Amp subagents have no inter-agent communication, so parallel Agent Teams is infeasible there.

### JJ Workspaces (Parallel Features)

Work on multiple features simultaneously in isolated directories using [JJ (Jujutsu)](https://martinvonz.github.io/jj/) colocated workspaces. Each workspace gets its own terminal-based agent session (Claude Code or Amp) and feature state machine, while sharing the same git commit graph.

```
Terminal 1 (primary):                    Terminal 2 (workspace):
  frndos/                                  frndos-feature-b/
  └─ feature: image-editor                 └─ feature: feature-b
     phase: implementation                    phase: prd_creation
     agent session A                          agent session B
```

**How it works:**
- JJ runs in colocated mode — all git commands stay unchanged
- JJ is only used for workspace management (`workspace add`, `workspace list`, `workspace forget`)
- Committed changes propagate instantly between workspaces (shared repo graph)
- Each workspace is independent — no cross-workspace phase dependencies

**Commands:**
- `/jj-workflow init` — Initialize JJ in service repos (one-time)
- `/jj-workflow new <slug>` — Create a sibling workspace directory
- `/jj-workflow list` — List all workspaces and their features
- `/jj-workflow cleanup <slug>` — Remove a completed workspace

**Requirements:** JJ installed (`brew install jj` or via `nix develop`). Best with terminal-based harnesses (Claude Code, Amp) — Cursor is IDE-integrated so benefits less.

### Creating a New Workspace for a Different Project

Use `/setup-workspace` to create a brand new agentic workspace for a completely different project using this framework as the base. The skill walks you through an interactive wizard:

1. Project identity (name, description, structure)
2. Services (repos, stack, ports, health checks)
3. Workflow phases (keep/remove/add from the default 11)
4. Agents (which phase agents, models, editor support)
5. Skills and MCP servers
6. Dev environment (flake.nix packages, branch conventions)

Then generates all configuration files — agents, fragments, skills, schemas, templates, and manifest.

### Skills

Skills are slash commands you invoke directly. They're the entry points for each workflow action.

> **Amp note:** Amp has no slash commands — it auto-loads skills based on their `description` frontmatter when you express the intent in natural language (e.g., "start a new feature called user-profiles" loads the workflow skill). The commands below are the canonical names; use the equivalent phrasing in Amp.

| Skill | What it does |
|-------|-------------|
| `/onboard` | Full workspace setup — GitHub access, service cloning, dependencies, .env files, database, editor config, MCP servers. Run once after bootstrap. |
| `/workflow start <slug>` | Start a new feature. Creates workflow state, enters PRD phase, delegates to the right agent. |
| `/workflow status` | Show current feature phase, branch, PRDs, wireframes, PRs — everything at a glance. |
| `/workflow next` | Advance to the next phase (checks gate conditions first). |
| `/workflow switch <slug>` | Context-switch between active features. Each keeps its own phase. |
| `/workflow resume <slug>` | Pick up someone else's feature. Reconstructs phase from committed artifacts. |
| `/workflow list` | List all local features with their phases. |
| `/workflow list-all` | Discover ALL features across the team — scans branches, PRDs, track files. |
| `/workflow mode` | Switch Claude Code between Agent Session (sequential) and Team Session (parallel). |
| `/workflow progress` | Detailed progress: phase timeline, task completion %, session logs. |
| `/workflow-update` | Update agentic-workflows instructions. Runs update script, summarizes changes, applies non-trivial updates (settings, schema migrations). |
| `/workflow-update check` | Dry-run — check for available updates without applying. |
| `/workflow-update verify` | Health check — verify symlinks, settings, AGENTS.md, version are correct. |
| `/prd` | Create a formal PRD from a Lark doc URL or your description. |
| `/prd-split` | Split a main PRD into per-service PRDs (API, Web, AI, Data). |
| `/wireframe` | Build production-quality static frontend pages for a feature. |
| `/jj-workflow init` | Initialize JJ colocated mode in service repos. |
| `/jj-workflow new <slug>` | Create a parallel workspace — isolated directory for a separate terminal-based agent session (Claude Code or Amp) to work on another feature simultaneously. |
| `/jj-workflow list` | List all JJ workspaces with their feature, phase, and worker. |
| `/jj-workflow status` | Show current workspace type (primary/secondary) and JJ state. |
| `/jj-workflow cleanup <slug>` | Remove a completed workspace — forget JJ workspaces, delete directory, update registry. |
| `/setup-workspace` | Interactive wizard to create a brand new agentic workspace for a different project using this framework as the base. |

### Agents

Agents are phase-scoped specialists. You never invoke them directly — the orchestra delegates based on workflow phase. Each agent has a specific model assignment optimized for its task.

| Agent | Model | Phase | What it does |
|-------|-------|-------|-------------|
| `frndos-orchestra` | Opus 4.5 | All | **The router.** Reads workflow state, delegates to the right agent, never does work itself. Handles branch creation and context switching. In Team Session mode, acts as the lead — creates the team, approves plans, coordinates reviews. |
| `frndos-prd` | Opus 4.6 | PRD Creation | Reads Lark docs (via MCP) or user input. Asks clarifying questions, challenges assumptions. Outputs a structured PRD with objectives, user stories, acceptance criteria, and technical scope. |
| `frndos-wireframe` | Opus 4.6 | Wireframe | Builds production-quality static frontend — not sketches. Uses frndos components, creates sub-pages for navigable views, includes all interactive states. Output is the actual UI that engineers wire up later. |
| `frndos-splitter` | Opus 4.6 | PRD Splitting | Reads the main PRD and generates per-service PRDs. Each service PRD has specific endpoints, migrations, models, components, or data pipelines scoped to that service. |
| `frndos-implement` | Opus 4.6 | Implementation | **Sequential mode only.** Implements across all services following service PRDs. Reads track files, presents plan, waits for approval, implements task-by-task, runs tests, commits per task. |
| `frndos-engineer` | Opus 4.6 | Implementation | **Team Session only.** One per service. Implements, self-reviews, creates PR for their assigned service. Communicates via mailbox. Cannot write code outside their service directory. |
| `frndos-architect` | Opus 4.6 | Implementation | **Team Session only.** Reviews cross-service integration — API contracts, shared types, data flow, auth consistency. Does NOT review code quality (engineer's self-review handles that). Does NOT write code. |
| `frndos-pr` | Sonnet 4.6 | PR phases | Creates PRs from templates, tags reviewers, handles feedback. Works for both wireframe PRs (targeting develop, FE owner review) and feature PRs (per-service, targeting develop/development). |
| `frndos-track` | Sonnet 4.6 | Completion | Updates track files with task completion, session logs, PR URLs. Marks features complete in workflow state. |

### How auto-update works

1. Edit files in this repo → push to `main`
2. GitHub Action computes SHA-256 hashes, bumps VERSION, updates `manifest.json`
3. On next agent session, `update-check.sh` compares local hashes vs manifest
4. Only changed files are downloaded — fragments, agents, skills, etc.
5. If fragments changed, `AGENTS.md` is regenerated automatically
6. For non-trivial changes (settings, schema migrations), use `/workflow-update`

### Repository structure

```
agentic-workflows/
  agents/
    fragments/            # Markdown fragments assembled into AGENTS.md
    tools/
      claude-code/        # Agent definitions (.md) for Claude Code
        frndos-orchestra  #   Router + lead (delegates, never implements)
        frndos-prd        #   PRD creation
        frndos-wireframe  #   Wireframe builder
        frndos-splitter   #   Splits PRD into service PRDs
        frndos-implement  #   Sequential implementation (fallback)
        frndos-engineer   #   Per-service engineer (Agent Teams)
        frndos-architect  #   Integration reviewer (Agent Teams)
        frndos-pr         #   PR creation and review
        frndos-track      #   Track file management
      cursor/             # Agent definitions (.mdc) for Cursor
      opencode/           # Agent definitions (.md) for OpenCode
      amp/                # Agent definitions (.md) for Amp (ampcode.com)
    AGENTS.md.template    # Template with {{FRAGMENT:...}} markers
  scripts/
    update-check.sh       # Downloads updates from this repo
    generate-agents.sh    # Assembles AGENTS.md from fragments
  skills/
    onboard/              # /onboard — full workspace setup
    workflow/             # /workflow — state machine management
    workflow-update/      # /workflow-update — update + apply non-trivial changes
    prd/                  # /prd — PRD creation
    prd-split/            # /prd-split — split PRD into service PRDs
    wireframe/            # /wireframe — wireframe builder
    jj-workflow/          # /jj-workflow — JJ workspace management for parallel features
    setup-workspace/      # /setup-workspace — wizard to create new agentic workspaces
  templates/
    prd/                  # PRD document templates
    pr/                   # PR body templates
    tracks/               # Track file templates
  workflow/
    phases.json           # 11-phase state machine definitions
    gates.json            # Gate conditions per phase transition
    state-schema.json     # JSON schema for .workflow-state.json
  wireframe-scaffold/
    layout.tsx            # Scaffold for /wireframes route
    page.tsx              # Scaffold for /wireframes index
  manifest.json           # File registry with SHA-256 hashes
  VERSION                 # Semver (patch auto-bumped by CI)
  flake.nix               # Nix flake for dev environment
```

### Making changes

1. Edit the file (agents, fragments, skills, templates, etc.)
2. Push to `main`
3. GitHub Action auto-updates `manifest.json` and `VERSION`
4. Everyone's agent picks up changes on next session

To add a new distributable file, add an entry to `manifest.json` with:
- File path as key, `sha256: "PLACEHOLDER"`, `install_to` path, and `type`

### Key conventions

- Commit messages with `[skip ci]` or `[manifest]` skip the update Action
- All distributable files must be registered in `manifest.json`
- Skills use the universal `.agents/skills/` path (symlinked to `.claude/`, `.cursor/`, `.opencode/`)
- Agents live in `.agentic-workflows/agents/<tool>/` (symlinked to `.claude/`, `.cursor/`, `.opencode/`)
