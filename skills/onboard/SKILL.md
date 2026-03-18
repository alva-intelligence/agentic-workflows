---
name: onboard
description: Full frndOS workspace onboarding — GitHub access, service setup, dependencies, editor config, and MCP configuration. Run this after bootstrap to set up your development environment.
---

# frndOS Workspace Onboarding

This skill guides you through setting up a complete frndOS development workspace. Execute steps in order. Steps marked **STOP** require user input — wait for answers before proceeding.

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

Per selected service (skip if user doesn't have .env):

- **API:** `cd api && composer install && cp .env.example .env && php artisan key:generate`
- **Frontend:** `cd web && bun install && cp .env.example .env.local`
- **AI Service:** `cd ai-service && pip install uv && uv venv && uv pip install -r requirements.txt && cp .env.example .env`
- **Data Service:** `cd data-service && python3 -m venv venv && pip install -r requirements.txt && cp .env.example .env`

Remind user to replace .env files with real credentials from contacts in Step 1.

## Step 6: Database Setup — **STOP, ask user**

Ask: "Do you have a PostgreSQL database dump (.dump file) for local development?"

- **Yes:** Help restore: `createdb frnd && psql frnd < path/to/dump.dump`
- **No:** "Contact arhen for a sanitized dev dump. The API won't work without it."

The dump is REQUIRED for API. Don't skip this step.

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

The bootstrap already installed agents and skills to `.agents/` with symlinks to `.claude/`, `.cursor/`, `.opencode/`.

**Additional per-tool setup:**

**Claude Code:** Verify `CLAUDE.md` symlink exists → `AGENTS.md`

**Cursor:** If user selected Cursor, check `.cursor/agents/` symlink exists. If not:
```bash
mkdir -p .cursor
ln -sf ../.agents/agents .cursor/agents
ln -sf ../.agents/skills .cursor/skills
```

**OpenCode:** Similar symlink check for `.opencode/`.

## Step 10: Configure MCPs (if selected)

See [references/mcp-configs.md](references/mcp-configs.md) for per-tool MCP configuration templates.

**Lark MCP:** Configure for each selected tool.
**Figma MCP:** Configure for each selected tool.

If neither was selected, skip.

## Step 11: Verify & Complete

1. Start services: `./run-all.sh --check` (preflight) then `./run-all.sh`
2. Run health checks for each service
3. Summarize what was set up

Tell user:
```
Workspace is ready! Your next step:
  /workflow start <feature-slug>    — begin a new feature
  /workflow status                  — check current state
```
