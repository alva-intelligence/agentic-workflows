---
name: onboard
description: Full frndOS workspace onboarding — GitHub access, service setup, dependencies, editor config, and MCP configuration. Run this after bootstrap to set up your development environment.
---

# frndOS Workspace Onboarding

This skill guides you through setting up a complete frndOS development workspace. Execute steps in order. Steps marked **STOP** require user input — wait for answers before proceeding.

## Asking the User (MANDATORY)

When you need user input, you MUST use your tool's dedicated ask/question tool:

- **Claude Code:** Use the `AskUserQuestion` tool with structured options
- **Cursor:** Use the built-in ask question tool
- **OpenCode:** Use the question tool with select/text modes

**NEVER** just print a question as plain text and hope the user responds. **ALWAYS** use the ask tool so the user gets a proper interactive prompt with selectable options. This prevents the agent from continuing without an answer.

## Onboarding State

Throughout onboarding, maintain a `.onboard-state.json` file at the workspace root. **Write/update this file after each step.**

```json
{
  "status": "in_progress|completed",
  "services": ["api", "web", "ai-service", "data-service"],
  "tools": ["claude-code", "cursor"],
  "steps": {
    "github_access": "completed|skipped|pending",
    "questionnaire": "completed|pending",
    "prerequisites": "completed|pending",
    "model_access": "completed|skipped|pending",
    "clone_repos": "completed|pending",
    "install_deps": "completed|pending",
    "env_files": "completed|partial|pending",
    "db_setup": "completed|skipped|pending",
    "run_all_sh": "completed|pending",
    "docs_structure": "completed|pending",
    "editor_tooling": "completed|pending",
    "community_skills": "completed|pending",
    "mcp_servers": "completed|pending",
    "verify": "completed|pending"
  },
  "env_status": {
    "api": "completed|pending",
    "web": "completed|pending",
    "ai-service": "completed|pending",
    "data-service": "completed|pending"
  },
  "skipped_reasons": {}
}
```

The workflow engine reads this file. **`/workflow start` will block** if any of these are not resolved:
- `env_files` is not `"completed"` for ALL selected services
- `db_setup` is not `"completed"` (required for API)
- `clone_repos` is not `"completed"`
- `install_deps` is not `"completed"`

The agent must remind the user what's missing and how to fix it.

## Step 0: Verify GitHub Access

```bash
# Check gh CLI
command -v gh &>/dev/null && echo "✓ gh CLI: $(gh --version | head -1)" || echo "✗ gh CLI not found — install from https://cli.github.com/"

# Check authentication
gh auth status &>/dev/null && echo "✓ Authenticated" || echo "✗ Not authenticated — run: gh auth login"

# Check org access
gh api user/orgs --jq '.[].login' | grep -q "alva-intelligence" && echo "✓ alva-intelligence org access" || echo "✗ No org access — contact arhen"
```

Check access to each repo:
- `gh repo view alva-intelligence/frnd-api-php` → API
- `gh repo view alva-intelligence/frnd-web` → Frontend
- `gh repo view alva-intelligence/frnd-ai-services` → AI Service
- `gh repo view alva-intelligence/frnd-clickhouse-api` → Data Service

Check git config: `git config --global user.name` and `git config --global user.email`.

## Step 1: Questionnaire — **STOP, ask all at once, wait for answers**

Present ALL questions in a single message:

### 1.1 Which services will you work on?

| # | Service | Directory | Stack |
|---|---------|-----------|-------|
| 1 | API | `api/` | Laravel 12, PHP 8.2+, PostgreSQL, Sanctum + JWT |
| 2 | Frontend | `web/` | Next.js 16, React 19, TypeScript, Tailwind, Bun |
| 3 | AI Service | `ai-service/` | FastAPI, Python, Agno, OpenAI/Anthropic/Google |
| 4 | Data Service | `data-service/` | FastAPI, Python, ClickHouse, pandas |

### 1.2 Do you have `.env` files ready?

| Service | Env File | Contact |
|---------|---------|---------|
| API | `api/.env` | arhen |
| Frontend | `web/.env.local` | fahrizky, daffa |
| AI Service | `ai-service/.env` | rifki |
| Data Service | `data-service/.env` | kemal, iru |

### 1.3 Which editor/CLI do you use?

Editors: Cursor, Zed, Antigravity
CLI Agents: Claude Code, OpenCode, Codex
(Can select multiple — this determines agent and MCP configuration)

### 1.4 Which AI provider subscriptions?

- Anthropic: Claude Opus 4.6 (planning), Claude Sonnet 4.6 (coding)
- OpenAI: GPT 5.3-codex (coding), GPT 5.4 (exploratory)

### 1.5 Optional integrations

- **Lark MCP** — Read PRDs directly from Lark doc URLs (skip copy-paste)
- **Figma MCP** — Read designs from Figma, extract component specs

Neither is required. Workflow works without them.

## Step 2: Check System Prerequisites

**Option A — Nix (recommended):**
```bash
if command -v nix &>/dev/null; then
  echo "✓ Nix installed"
else
  echo "Nix not found. Install with: curl -L https://nixos.org/nix/install | sh"
fi
```
If Nix is available, `nix develop` in workspace root provides all dependencies.

**Option B — Manual checks** (only for services user selected):
```bash
# Runtimes
for cmd in php bun python3 node; do command -v "$cmd" &>/dev/null && echo "✓ $cmd" || echo "✗ $cmd missing"; done

# Package managers
for cmd in composer uv pip; do command -v "$cmd" &>/dev/null && echo "✓ $cmd" || echo "✗ $cmd missing"; done

# Databases
command -v psql &>/dev/null && echo "✓ PostgreSQL" || echo "✗ PostgreSQL missing"
command -v redis-cli &>/dev/null && echo "✓ Redis" || echo "○ Redis (optional)"

# Dev tools
for cmd in git gh; do command -v "$cmd" &>/dev/null && echo "✓ $cmd" || echo "✗ $cmd missing"; done
```

Help install any missing prerequisites before continuing.

## Step 3: Verify Model Access

Based on CLI choice and subscriptions from Step 1:

**Claude Code:**
```bash
echo "OK" | claude -p --model claude-opus-4-6 2>&1 | head -1
echo "OK" | claude -p --model claude-sonnet-4-6 2>&1 | head -1
```

**OpenCode:**
```bash
opencode run -m anthropic/claude-opus-4-6 "respond with just OK" 2>&1 | head -5
```

Report which models work and suggest fallbacks for any that fail.

## Step 4: Clone Repositories

Only clone services the user selected. Skip if directory already exists.

```bash
# API
[ -d "api" ] || (git clone git@github.com:alva-intelligence/frnd-api-php.git api && cd api && git checkout develop)

# Frontend
[ -d "web" ] || (git clone https://github.com/alva-intelligence/frnd-web web && cd web && git checkout develop)

# AI Service
[ -d "ai-service" ] || (git clone https://github.com/alva-intelligence/frnd-ai-services ai-service && cd ai-service && git checkout development)

# Data Service
[ -d "data-service" ] || (git clone git@github.com:alva-intelligence/frnd-clickhouse-api.git data-service && cd data-service && git checkout development)
```

## Step 5: Install Dependencies

Per selected service, install dependencies. **Always install deps even if user doesn't have .env yet** — deps are needed regardless.

- **API:** `cd api && composer install && cp .env.example .env && php artisan key:generate`
- **Frontend:** `cd web && bun install && cp .env.example .env.local`
- **AI Service:** `cd ai-service && pip install uv && uv venv && uv pip install -r requirements.txt && cp .env.example .env`
- **Data Service:** `cd data-service && python3 -m venv venv && pip install -r requirements.txt && cp .env.example .env`

Update `.onboard-state.json`: set `steps.install_deps` to `"completed"`.

## Step 6: Set Up Environment Files — **STOP, ask for EACH service**

The `.env.example` files were copied in Step 5, but they contain placeholder values. **Each service needs real credentials to run.**

For EACH selected service, ask the user:

> "Do you have the real `.env` file for **[service]**? You need it from **[contact]**."

| Service | Env File | What User Must Do | Contact |
|---------|---------|-------------------|---------|
| API | `api/.env` | Replace `api/.env` with real credentials | arhen |
| Frontend | `web/.env.local` | Replace `web/.env.local` with real credentials | fahrizky, daffa |
| AI Service | `ai-service/.env` | Replace `ai-service/.env` with real credentials | rifki |
| Data Service | `data-service/.env` | Replace `data-service/.env` with real credentials | kemal, iru |

**For each service, one of:**
- **"I have it"** → Ask user to drop/paste the file, or confirm it's already in place. Verify the file exists and is NOT the example: check it doesn't contain `your-secret-here` or `CHANGE_ME` placeholder patterns. Mark `env_status.<service>` as `"completed"`.
- **"I don't have it yet"** → Mark `env_status.<service>` as `"pending"`. Tell user who to contact. **Continue onboarding** — don't block here, but record it.

After checking all services:
- If ALL selected services have real .env files → set `steps.env_files` to `"completed"`
- If ANY are pending → set `steps.env_files` to `"partial"` and list what's missing

**The user can continue onboarding with partial .env setup, but `/workflow start` will block until ALL are completed.**

## Step 7: Database Setup — **STOP, ask user**

Ask: "Do you have a PostgreSQL database dump (.dump file) for local development?"

- **"Yes, I have the dump file":**
  1. Ask for the file path (e.g., `~/Downloads/frnd-dev.dump`)
  2. Create the database: `createdb frnd` (or whatever DB name is in `api/.env`)
  3. Restore: `pg_restore -d frnd path/to/dump.dump` or `psql frnd < path/to/dump.dump`
  4. Run migrations: `cd api && php artisan migrate`
  5. Mark `steps.db_setup` as `"completed"`

- **"No, I don't have it":**
  1. Tell user: "Contact **arhen** for a sanitized dev database dump. The API needs it to function."
  2. Mark `steps.db_setup` as `"skipped"` with reason
  3. **Continue onboarding** — don't block here

**The DB dump is REQUIRED for API.** `/workflow start` will block if `db_setup` is not `"completed"` and the user selected the API service.

## Step 7: Create run-all.sh

If `run-all.sh` doesn't exist in the workspace root, create it from the template at [references/run-all-template.sh](references/run-all-template.sh).

Make it executable: `chmod +x run-all.sh`

## Step 8: Set Up Documentation Structure

```bash
mkdir -p docs/prd
for service in api web ai-service data-service; do
  if [ -d "$service" ]; then
    mkdir -p "$service/docs/prd" "$service/docs/tracks"
  fi
done
```

## Step 9: Configure Editor Tooling

The bootstrap already installed frndOS agents and skills to `.agents/` with symlinks to `.claude/`, `.cursor/`, `.opencode/`.

**Additional per-tool setup:**

**Claude Code:** Verify `CLAUDE.md` symlink exists → `AGENTS.md`

**Cursor:** If user selected Cursor, check `.cursor/agents/` symlink exists. If not:
```bash
mkdir -p .cursor
ln -sf ../.agents/agents .cursor/agents
ln -sf ../.agents/skills .cursor/skills
```

**OpenCode:** Similar symlink check for `.opencode/`.

## Step 10: Install Community Skills

Skills are installed via [skills.sh](https://skills.sh/) using `npx skills add`. Install based on which services the user works on.

**Always install (cross-service):**
```bash
npx skills add github/awesome-copilot/git-commit        # conventional commit messages
npx skills add github/awesome-copilot/prd                # PRD creation
```

**If user works on Frontend (`web/`):**
```bash
npx skills add anthropics/skills/frontend-design         # production-grade UI
npx skills add vercel-labs/agent-skills                   # react best practices
npx skills add vercel-labs/next-skills                    # next.js best practices
npx skills add busirocket/tailwindcss-v4                  # tailwind CSS v4
npx skills add radix-ui/design-system                     # accessible components
```

> Browse more skills at [skills.sh](https://skills.sh/) or use `npx skills add vercel-labs/skills/find-skills`.

## Step 11: Configure MCP Servers

Each tool reads MCP config from a different path:

| Tool | Config File |
|------|-------------|
| Claude Code | `.mcp.json` (repo root) |
| OpenCode | `opencode.json` (repo root) |
| Cursor | `.cursor/mcp.json` |

### Required MCPs (always configure)

| MCP Server | Purpose | For Service |
|-----------|---------|-------------|
| **Context7** | Up-to-date library/framework documentation lookup | All |
| **GitHub** | PR management, issue tracking, repository operations | All |
| **Laravel Boost** | Laravel docs, tinker, artisan, DB queries | API only |

### Optional MCPs (based on Step 1 answers)

| MCP Server | Purpose |
|-----------|---------|
| **Lark** | Read PRDs directly from Lark doc URLs |
| **Figma** | Design-to-code translation |
| **Sentry** | Error tracking and monitoring |

See [references/mcp-configs.md](references/mcp-configs.md) for per-tool configuration templates.

Configure MCPs in the correct file for the user's selected tool(s). For service-specific MCPs (Laravel Boost), configure inside the service directory, not the workspace root.

## Step 12: Verify & Complete

1. Run preflight: `./run-all.sh --check`
2. If all checks pass, try starting: `./run-all.sh`
3. Run health checks for each selected service
4. Update `.onboard-state.json`: set `steps.verify` to `"completed"`

**Check for incomplete items.** Read `.onboard-state.json` and report:

If ALL critical steps are completed:
```
Onboarding complete! Your workspace is fully set up.

Next step:
  /workflow start <feature-slug>    — begin a new feature
  /workflow status                  — check current state
```
Set `status` to `"completed"`.

If ANY critical steps are pending/skipped:
```
Onboarding mostly done, but some items need attention before you can start working:

  Missing .env files:
    - api/.env — contact arhen
    - ai-service/.env — contact rifki

  Database:
    - DB dump not restored — contact arhen for a sanitized dev dump

You can complete these later. When ready, the agent will verify automatically.
To re-check: /onboard verify
```
Keep `status` as `"in_progress"`.

## /onboard verify

If the user runs `/onboard verify` (or any agent checks onboarding state):

1. Read `.onboard-state.json`
2. For each pending env file, check if the real file now exists (not a placeholder)
3. For pending db_setup, check if `psql -h localhost -p 5432 -d frnd -c "SELECT 1"` succeeds
4. Update the state file with any newly completed items
5. Report what's still missing

## /onboard resume

If the user runs `/onboard resume`:

1. Read `.onboard-state.json`
2. Find the first step that is `"pending"` or `"skipped"`
3. Continue onboarding from that step
