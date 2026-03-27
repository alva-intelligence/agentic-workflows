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
  - 6 skills (/onboard, /workflow, /workflow-update, /prd, /prd-split, /wireframe)
  - An 11-phase workflow state machine with gate enforcement
  - Agent Teams support — parallel per-service engineers + architect (Claude Code)
  - Auto-updating instruction system (stays in sync with team changes)
  - Templates for PRDs, service PRDs, track files, and PRs

Supported tools: Claude Code, Cursor, OpenCode (and any tool supporting SKILL.md)
```

### Step 2: Ask for confirmation

Use your **ask tool** (Claude Code: `AskUserQuestion`, Cursor: ask tool, OpenCode: question tool):

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

**To bootstrap from a specific branch** (e.g., `claude-teams` for Agent Teams features):

```bash
curl -sL "https://raw.githubusercontent.com/alva-intelligence/agentic-workflows/claude-teams/scripts/update-check.sh" \
  -o /tmp/aw-update-check.sh && bash /tmp/aw-update-check.sh --bootstrap --branch=claude-teams
```

The `--branch` flag is persisted — subsequent update checks automatically track the same branch. You can also set `AW_BRANCH=claude-teams` as an env var.

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

**Sequential fallback:** Cursor, OpenCode, or when the env var is unset — uses `frndos-implement` → `frndos-pr` (unchanged).

### How auto-update works

1. Edit files in this repo → push to `main` (or a feature branch)
2. GitHub Action computes SHA-256 hashes, bumps VERSION, updates `manifest.json`
3. On next agent session, `update-check.sh` compares local hashes vs manifest
4. Only changed files are downloaded — fragments, agents, skills, etc.
5. If fragments changed, `AGENTS.md` is regenerated automatically
6. For non-trivial changes (settings, schema migrations), use `/workflow-update`

**Branch tracking:** Workspaces bootstrapped with `--branch=<branch>` persist the branch in `.agentic-workflows/.branch` and automatically pull updates from that branch on subsequent checks.

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
    AGENTS.md.template    # Template with {{FRAGMENT:...}} markers
  scripts/
    update-check.sh       # Downloads updates (supports --branch=<branch>)
    generate-agents.sh    # Assembles AGENTS.md from fragments
  skills/
    onboard/              # /onboard — full workspace setup
    workflow/             # /workflow — state machine management
    workflow-update/      # /workflow-update — update + apply non-trivial changes
    prd/                  # /prd — PRD creation
    prd-split/            # /prd-split — split PRD into service PRDs
    wireframe/            # /wireframe — wireframe builder
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
- Agents use `.agents/agents/` (similarly symlinked)
