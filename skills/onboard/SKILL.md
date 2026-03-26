---
name: onboard
description: Full frndOS workspace onboarding — GitHub access, service setup, dependencies, editor config, and MCP configuration. Run this after bootstrap to set up your development environment.
---

# frndOS Workspace Onboarding

This skill guides you through setting up a complete frndOS development workspace. Execute steps in order. Steps marked **STOP** require user input — wait for answers before proceeding.

## Interaction Model — READ THIS FIRST

> **1. Switch to plan mode first.** Before executing anything, switch to your CLI/editor's planning mode:
>   - **Claude Code:** Enter plan mode (`/plan` or Shift+Tab)
>   - **Cursor:** Use chat mode (not agent mode)
>   - **OpenCode:** Switch to Plan agent (Tab)
>
> This ensures you present plans and questions to the user and wait for approval before executing.
>
> **2. Steps 0–1 are interactive.** Present ALL questions, wait for answers. Do NOT assume or skip.
>
> **3. After Step 1 — switch to execution mode:**
>   - **Claude Code:** Exit plan mode (normal mode)
>   - **Cursor:** Switch to agent mode
>   - **OpenCode:** Switch to Build agent (Tab)
>
> **4. Create a todo checklist** based on user's Step 1 answers. Only include items for selected services/tools. Mark items as you complete them.
>
> **5. Only set up what the user selected.** Do not install everything by default.
>
> **6. After each step,** briefly summarize what was done before moving to the next.

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

| # | Service | Directory | Stack | Port(s) |
|---|---------|-----------|-------|---------|
| 1 | API | `api/` | Laravel 13, PHP 8.5, PostgreSQL, Sanctum + JWT | :9191 (server) + queue worker |
| 2 | Frontend | `web/` | Next.js 16, React 19, TypeScript, Tailwind, Bun | :3000 |
| 3 | AI Service | `ai-service/` | FastAPI, Python, Agno, OpenAI/Anthropic/Google | :8000 |
| 4 | Data Service | `data-service/` | FastAPI, Python, pandas | :9999 |

**Also started automatically by `run-all.sh`:**
- **API Queue Worker** — processes background jobs (always runs with API)
- **Mailhog** — captures emails sent by the API for local testing (:1025 SMTP, :8025 UI)

### 1.2 Do you have `.env` files ready?

| Service | Env File | Contact |
|---------|---------|---------|
| API | `api/.env` | arhen |
| Frontend | `web/.env.local` | fahrizky, daffa |
| AI Service | `ai-service/.env` | rifki |
| Data Service | `data-service/.env` | kemal, iru |

### 1.3 Which editor/CLI do you use?

Use the ask tool with these EXACT options (multi-select):

| # | Tool | Type | Description |
|---|------|------|-------------|
| 1 | Claude Code | CLI Agent | Best for complex multi-service tasks, strong tool use |
| 2 | OpenCode | CLI Agent | Lightweight, fast, configurable |
| 3 | Cursor | Editor | Deep AI integration, multi-file editing, agent mode |
| 4 | Codex | CLI Agent | OpenAI-native code generation |
| 5 | Zed | Editor | Fast, lightweight, multiplayer |
| 6 | Other | — | Type your own |

(Can select multiple — this determines agent, skill, and MCP configuration)

### 1.4 Which AI provider subscriptions?

- Anthropic: Claude Opus 4.6 (planning), Claude Sonnet 4.6 (coding)
- OpenAI: GPT 5.3-codex (coding), GPT 5.4 (exploratory)

### 1.5 Optional integrations

- **Lark MCP** — Read PRDs directly from Lark doc URLs (skip copy-paste)
- **Figma MCP** — Read designs from Figma, extract component specs

Neither is required. Workflow works without them.

---

> **Switch to execution mode now.** The user has answered all questions.
> - **Claude Code:** Exit plan mode (normal mode)
> - **Cursor:** Switch to agent mode
> - **OpenCode:** Switch to Build agent (Tab)
>
> **Create a todo checklist now.** Based on the user's answers, create a task list covering Steps 2–12. Only include items relevant to the services, tools, and providers the user selected. Mark each item as you complete it.

---

## Step 2: Set Up Development Environment

Use the ask tool:

> "How do you want to set up your development environment?"
> - **Nix** (recommended) — Reproducible, all versions pinned, one command gives you everything
> - **Direct install** — Use homebrew/manual install on your Mac

Record the choice in `.onboard-state.json` as `"env_method": "nix"` or `"env_method": "direct"`.

---

### Option A: Nix

#### A.1 Check if Nix is installed and flakes are enabled

```bash
command -v nix &>/dev/null && echo "✓ Nix installed: $(nix --version)" || echo "✗ Nix not found"
```

If Nix IS installed, ensure flakes are enabled (idempotent):

```bash
mkdir -p ~/.config/nix
grep -q 'experimental-features' ~/.config/nix/nix.conf 2>/dev/null || echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

If Nix is installed and flakes work, skip to A.3.

#### A.2 If Nix is NOT installed — **STOP, wait for user**

Nix requires `sudo`. The agent CANNOT install it headlessly. Use the ask tool:

> "Nix is not installed. Please run this in a separate terminal:
> ```
> curl -L https://nixos.org/nix/install | sh
> ```
> **Let me know when the installation finishes.**"

**STOP AND WAIT.** Use the ask tool:
> "Have you installed Nix?"
> - Yes, it's installed
> - Not yet, I need more time

After confirmation, enable flakes:
```bash
mkdir -p ~/.config/nix
grep -q 'experimental-features' ~/.config/nix/nix.conf 2>/dev/null || echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

Verify (use full path if PATH hasn't refreshed):
```bash
NIX_CMD=$(command -v nix 2>/dev/null || echo "/nix/var/nix/profiles/default/bin/nix")
$NIX_CMD --version
```

#### A.3 Enter the Nix dev shell

The agent runs this directly:
```bash
NIX_CMD=$(command -v nix 2>/dev/null || echo "/nix/var/nix/profiles/default/bin/nix")
$NIX_CMD develop
```

**First time may take 5-15 minutes** (downloading packages). Use a long timeout (600s). DO NOT panic or retry.

After completion, all tools are in PATH. All subsequent commands run directly — no wrappers needed.

#### A.4 Verify tools

```bash
php --version && composer --version && bun --version && node --version && python3 --version && uv --version && psql --version && redis-cli --version
```

If anything is missing, fix `flake.nix` — do NOT install manually.

#### A.5 All subsequent commands run in this shell

> **Do NOT use brew, apt, pip install --global, npm install -g.** Everything comes from Nix.

---

### Option B: Direct Install (Homebrew)

#### B.1 Check what's installed and version status

First check if `brew` is available:
```bash
command -v brew &>/dev/null && echo "✓ Homebrew installed" || echo "✗ Homebrew not found — install from https://brew.sh"
```

Then check each tool. For each one, determine: **missing**, **correct version**, or **wrong version**.

```bash
echo "=== Dev Tools (update to latest is fine) ==="
for cmd in php bun node python3 composer uv pip git gh redis-cli mailhog; do
  command -v "$cmd" &>/dev/null && echo "✓ $cmd: $($cmd --version 2>&1 | head -1)" || echo "✗ $cmd: NOT FOUND"
done

echo "=== PostgreSQL (keep if >= 16) ==="
command -v psql &>/dev/null && echo "✓ psql: $(psql --version 2>&1)" || echo "✗ psql: NOT FOUND"
```

#### B.2 Install or upgrade tools

The agent checks each tool and takes the right action. **Do this directly — do NOT ask user to run commands.**

**Tools that MUST match pinned versions — safe to upgrade (no data loss):**

| Tool | Pin | Check | Action |
|------|-----|-------|--------|
| PHP | **8.5** | `php -v \| grep "8.5"` | Missing → `brew install php@8.5`. Wrong version → `brew install php@8.5 && brew unlink php && brew link php@8.5 --force` |
| Node | **22** | `node -v \| grep "v22\."` | Missing → `brew install node@22`. Wrong version → **ask user** (see below) |
| Python | **3.12** | `python3 -V \| grep "3.12"` | Missing → `brew install python@3.12`. Wrong version → **ask user** (see below) |
| Bun | latest | `command -v bun` | Missing → `brew install oven-sh/bun/bun`. Installed → `brew upgrade bun` |
| Composer | latest | `command -v composer` | Missing → `brew install composer`. Installed → `brew upgrade composer` |
| uv | latest | `command -v uv` | Missing → `brew install uv`. Installed → `brew upgrade uv` |

**If a pinned tool is installed but wrong version**, use the ask tool:

> "You have **Node v23.8.0** installed, but frndOS pins **Node 22**. What would you like to do?"
> - Install Node 22 alongside and switch to it (recommended)
> - Keep my current version (v23) — I'll handle compatibility myself

If user says **install and switch** → `brew install node@22 && brew unlink node && brew link node@22 --force`
If user says **keep current** → skip, continue onboarding. Note in `.onboard-state.json` that version differs from pin.

Apply the same pattern for Python, PHP, or any pinned tool with a version mismatch. **NEVER silently downgrade** — always ask first.

**PostgreSQL — KEEP existing if version >= 16 (upgrading deletes data):**

```bash
pg_version=$(psql --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
if [ -z "$pg_version" ]; then
  echo "✗ PostgreSQL not found — installing 18"
  brew install postgresql@18
elif [ "$pg_version" -ge 16 ]; then
  echo "✓ PostgreSQL $pg_version — keeping (>= 16 is fine)"
else
  echo "⚠ PostgreSQL $pg_version is too old (need >= 16)"
  # Ask user before upgrading — it will delete their data
fi
```

**If PostgreSQL is < 16**, use the ask tool:
> "Your PostgreSQL is version $pg_version. frndOS needs >= 16. Upgrading will delete existing databases. Should I upgrade?"
> - Yes, upgrade (I'll restore from dump later)
> - No, I'll handle it myself

**Other services — install if missing, keep if exists:**

| Tool | Check | Action |
|------|-------|--------|
| Redis | `command -v redis-cli` | Missing → `brew install redis`. Installed → keep |
| Mailhog | `command -v mailhog` | Missing → `brew install mailhog`. Installed → keep |
| git | `command -v git` | Missing → `brew install git`. Installed → keep |
| gh | `command -v gh` | Missing → `brew install gh`. Installed → keep |

#### B.3 Verify all versions after install

```bash
php -v 2>&1 | grep -q "PHP 8.5" && echo "✓ PHP 8.5" || echo "✗ PHP — need 8.5"
node -v 2>&1 | grep -q "v22\." && echo "✓ Node 22" || echo "✗ Node — need 22"
python3 --version 2>&1 | grep -q "3.12" && echo "✓ Python 3.12" || echo "✗ Python — need 3.12"
pg_version=$(psql --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
[ "$pg_version" -ge 16 ] 2>/dev/null && echo "✓ PostgreSQL $pg_version" || echo "✗ PostgreSQL — need >= 16"
command -v bun &>/dev/null && echo "✓ Bun $(bun --version)" || echo "✗ Bun missing"
command -v composer &>/dev/null && echo "✓ Composer" || echo "✗ Composer missing"
command -v uv &>/dev/null && echo "✓ uv" || echo "✗ uv missing"
command -v redis-cli &>/dev/null && echo "✓ Redis" || echo "✗ Redis missing"
```

All pinned versions must match. If anything fails, fix before continuing.

#### B.4 Start database services (if not already running)

```bash
# Start PostgreSQL (use whatever version is installed)
brew services start postgresql@$(psql --version 2>/dev/null | grep -oE '[0-9]+' | head -1) 2>/dev/null || brew services start postgresql

# Start Redis
brew services start redis

# Verify
pg_isready -h localhost -p 5432 && echo "✓ PostgreSQL running" || echo "✗ PostgreSQL not running"
redis-cli ping && echo "✓ Redis running" || echo "✗ Redis not running"
```

#### B.4 Install pgvector extension

```bash
# pgvector for AI service vector search
psql -h localhost -p 5432 -d postgres -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || echo "pgvector may need manual install: brew install pgvector"
```

#### B.5 Verify all tools

```bash
php --version && composer --version && bun --version && node --version && python3 --version && uv --version && psql --version && redis-cli --version
```

All tools must be available. If any are missing, troubleshoot before continuing.

---

### After either option — record and continue

Save the environment method in `.onboard-state.json` and proceed to Step 3. All subsequent steps (clone, deps, .env, DB) work the same regardless of Nix or direct install.

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

**The agent MUST run these commands directly** — you are already inside `nix develop` from Step 2.3, so all tools (php, composer, bun, python3, uv) are available. No `nix develop --command` wrappers needed.

**Run sequentially, one service at a time. Do NOT ask user to run these manually.**

### 5.1 Set up Python virtual environments FIRST (AI Service + Data Service)

These must exist before installing Python deps:

```bash
# AI Service — uses uv for venv
cd ai-service && uv venv && cd ..

# Data Service — uses standard venv as .venv
cd data-service && python3 -m venv .venv && cd ..
```

### 5.2 Install deps per service

**Do NOT create .env files from .env.example.** The user will provide real .env files in Step 6.

```bash
# API (no .env copy — user provides real one later)
cd api && composer install --no-interaction; cd ..

# Frontend (no .env copy — user provides real one later)
cd web && bun install; cd ..

# AI Service (venv already created in 5.1)
cd ai-service && source .venv/bin/activate && uv pip install -r requirements.txt && deactivate; cd ..

# Data Service (venv already created in 5.1)
cd data-service && source .venv/bin/activate && pip install -r requirements.txt && deactivate; cd ..
```

**IMPORTANT:**
- **Do NOT run `cp .env.example .env`** — the user will drop real .env files in Step 6.
- **Do NOT run `php artisan key:generate`** yet — needs real .env first.
- Run each service one at a time. Wait for completion before starting the next.
- If a command fails, show the error and ask user if they want to retry or skip.
- The agent runs these directly. Never show commands and ask user to run them.

Update `.onboard-state.json`: set `steps.install_deps` to `"completed"`.

## Step 6: Set Up Environment Files — **STOP**

**Each service needs real credentials. The user must provide .env files before the project can run.**

Use the ask tool:

> "Do you have the `.env` files for your services? Each service needs real credentials from the service owner."
>
> | Service | Env File | Contact |
> |---------|---------|---------|
> | API | `api/.env` | arhen |
> | Frontend | `web/.env.local` | fahrizky, daffa |
> | AI Service | `ai-service/.env` | rifki |
> | Data Service | `data-service/.env` | kemal, iru |
>
> - Yes, I have all the .env files ready
> - I have some but not all
> - No, I'll get them later

**If "Yes, I have all" or "I have some":**

1. Tell user: "Please paste or upload each .env file content here. I'll write them to the correct locations."
2. **STOP AND WAIT** for user to paste/upload. The user may send one file at a time or all at once.
3. For each .env content the user provides:
   - Identify which service it belongs to (look for service-specific keys like `DB_DATABASE` for API, `NEXT_PUBLIC_` for Frontend, etc.)
   - Write the content to the correct path:
     - API → `api/.env`
     - Frontend → `web/.env.local`
     - AI Service → `ai-service/.env`
     - Data Service → `data-service/.env`
   - If you can't identify the service, ask the user which service it's for
4. After writing each file, confirm: "✓ Written to `<path>`"
5. After all files are written, verify:
   ```bash
   [ -f api/.env ] && echo "✓ api/.env" || echo "✗ api/.env missing"
   [ -f web/.env.local ] && echo "✓ web/.env.local" || echo "✗ web/.env.local missing"
   [ -f ai-service/.env ] && echo "✓ ai-service/.env" || echo "✗ ai-service/.env missing"
   [ -f data-service/.env ] && echo "✓ data-service/.env" || echo "✗ data-service/.env missing"
   ```
6. If any selected services are still missing .env, ask user to provide them before continuing.
7. Once all .env files are in place, **run post-env setup for API:**
   ```bash
   cd api && php artisan key:generate --no-interaction && cd ..
   ```
8. Mark `env_status` per service and set `steps.env_files` accordingly.

**If "No, I'll get them later":**
- Mark all `env_status.<service>` as `"pending"`
- Tell user: "Contact the service owners listed above. `/workflow start` will block until all .env files are provided."
- Continue onboarding with remaining steps

**The user can continue onboarding with missing .env files, but `/workflow start` will block until ALL are provided.**

## Step 7: Initialize Local Databases & Services

### 7.1 Initialize PostgreSQL data directory (one-time)

PostgreSQL from nix needs a local data directory. This is a one-time setup:

```bash
NIX_CMD=$(command -v nix 2>/dev/null || echo "/nix/var/nix/profiles/default/bin/nix")

# Initialize PostgreSQL data directory (skip if already exists)
if [ ! -d ".pgdata" ]; then
  $NIX_CMD develop --command bash -c "initdb -D .pgdata"
  echo "✓ PostgreSQL data directory created at .pgdata/"
fi
```

Then start PostgreSQL and enable pgvector:

```bash
# Start PostgreSQL in background
$NIX_CMD develop --command bash -c "pg_ctl -D .pgdata -l .logs/postgresql.log start"

# Wait for it to be ready
sleep 2
$NIX_CMD develop --command bash -c "pg_isready -h localhost -p 5432"

# Enable pgvector extension (one-time, for AI service vector search)
$NIX_CMD develop --command bash -c "psql -h localhost -p 5432 -d postgres -c 'CREATE EXTENSION IF NOT EXISTS vector;'" 2>/dev/null || true
```

### 7.2 Start Redis

```bash
# Start Redis in background
$NIX_CMD develop --command bash -c "redis-server --daemonize yes --logfile .logs/redis.log"

# Verify
$NIX_CMD develop --command bash -c "redis-cli ping"
```

### 7.3 Restore database dump — **STOP, ask user**

Use the ask tool:

> "Do you have a PostgreSQL database dump (.dump file) for local development?"
> - Yes, I have the dump file ready
> - No, but I can get it now from arhen
> - No, I'll get it later

**If "Yes, I have the dump file":**

1. Ask user: "Please provide the file path to the dump (e.g., `~/Downloads/frnd-dev.dump`)"
2. **STOP AND WAIT** for user to provide the path
3. Use the ask tool: "Is the dump file ready at the path you provided?"
4. Use the ask tool to ask the database name:
   > "What database name do you want to use for the restore? (e.g., `frnd`, `frndos`, etc.)"
5. **STOP AND WAIT** for user to provide the name.
6. Check if the database exists:
   ```bash
   psql -h localhost -p 5432 -lqt | cut -d\| -f1 | grep -qw <db_name>
   ```
   - **If it does NOT exist** → create it: `createdb <db_name>`
   - **If it DOES exist** → use the ask tool:
     > "Database `<db_name>` already exists. Should I drop and recreate it? All existing data will be lost."
     > - Yes, clean and recreate
     > - No, cancel
     If yes: `dropdb <db_name> && createdb <db_name>`
7. Restore the dump:
   ```bash
   pg_restore -d <db_name> <path> 2>/dev/null || psql <db_name> < <path>
   ```
8. Run migrations:
   ```bash
   cd api && php artisan migrate --no-interaction; cd ..
   ```
9. Verify: `psql -h localhost -p 5432 -d <db_name> -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'"` — should return > 0
10. **Remind user to update api/.env:**
    > "Database restored to `<db_name>`. **Make sure `DB_DATABASE=<db_name>` in your `api/.env` before we verify services.**"
11. Mark `steps.db_setup` as `"completed"`

**If "No, but I can get it now":**

1. Tell user: "Contact **arhen** for the sanitized dev dump. I'll wait."
2. **STOP AND WAIT** for user to come back with the file
3. Use the ask tool periodically: "Do you have the dump file now?"
4. Once provided, proceed with restore as above

**If "No, I'll get it later":**

1. Mark `steps.db_setup` as `"skipped"` with reason
2. Tell user: "The API won't function without the database. `/workflow start` will block until this is done."
3. Continue onboarding with remaining steps

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

The bootstrap already installed frndOS agents and skills to `.agents/` (Claude Code) and `.agentic-workflows/agents/` (Cursor/OpenCode), with symlinks to `.claude/`, `.cursor/`, `.opencode/`.

**Additional per-tool setup:**

**Claude Code:** Verify `CLAUDE.md` symlink exists → `AGENTS.md`. Agents are in `.agents/agents/`.

**Cursor:** If user selected Cursor, check `.cursor/agents/` symlink exists pointing to Cursor-specific `.mdc` agents. If not:
```bash
mkdir -p .cursor
ln -sf ../.agentic-workflows/agents/cursor .cursor/agents
ln -sf ../.agents/skills .cursor/skills
```

**OpenCode:** If user selected OpenCode, check `.opencode/agents/` symlink exists pointing to OpenCode-specific agents. If not:
```bash
mkdir -p .opencode
ln -sf ../.agentic-workflows/agents/opencode .opencode/agents
ln -sf ../.agents/skills .opencode/skills
```

### Dev Server Configuration (launch.json)

For tools that support `launch.json` (Claude Code Desktop), generate the dev server config so the agent can start/stop/preview services automatically.

**Check `env_method` from `.onboard-state.json`** to determine the format:

**If Nix:**
1. Copy template: `cp .agents/skills/onboard/references/launch.json .claude/launch.json`
2. Remove entries for services the user didn't select
3. Done — commands are wrapped with `nix develop --command`

**If Direct install:**
1. Copy template: `cp .agents/skills/onboard/references/launch-direct.json .claude/launch.json`
2. Remove entries for services the user didn't select
3. Done — commands run directly (tools in system PATH)

The template configures:

| Name | Command | cwd | Port |
|------|---------|-----|------|
| postgresql | `postgres -D .pgdata -k /tmp` | workspace root | 5432 |
| redis | `redis-server` | workspace root | 6379 |
| mailhog | `mailhog` | workspace root | 8025 |
| api | `php artisan serve --port=9191` | `api/` | 9191 |
| api-queue | `php artisan queue:work database ...` | `api/` | — |
| web | `bun run dev` | `web/` | 3000 |
| ai-service | `fastapi dev` | `ai-service/` | 8000 |
| data-service | `uvicorn app.main:app --reload --port 9999` | `data-service/` | 9999 |

All commands are wrapped with `nix develop --command` so they work even outside the nix shell. Infrastructure services (PostgreSQL, Redis) should start before app services.

## Step 10: Install Community Skills

Skills are installed via [skills.sh](https://skills.sh/) using `npx skills add`.

**IMPORTANT: Always use `--yes` flag** — the skills CLI requires an interactive TTY for prompts. Without `--yes`, the install will hang in agent sessions.

**Always install (cross-service):**
```bash
npx skills add https://github.com/github/awesome-copilot --skill git-commit --yes
npx skills add https://github.com/github/awesome-copilot --skill prd --yes
```

**If user works on Frontend (`web/`):**
```bash
npx skills add anthropics/skills@frontend-design --yes
npx skills add vercel-labs/agent-skills@vercel-react-best-practices --yes
npx skills add vercel-labs/next-skills@next-best-practices --yes
npx skills add busirocket/agents-skills@busirocket-tailwindcss-v4 --yes
npx skills add sickn33/antigravity-awesome-skills@radix-ui-design-system --yes
```

> **Note:** Some skills need full URL + `--skill` flag (e.g., `awesome-copilot`). Others use `owner/repo@skill-name` syntax. The `--yes` flag skips interactive prompts. Browse more at [skills.sh](https://skills.sh/) or search: `npx skills find <query>`.

## Step 11: Configure MCP Servers

Each tool reads MCP config from a different path:

| Tool | Config File |
|------|-------------|
| Claude Code | `.mcp.json` (repo root) |
| OpenCode | `opencode.json` (repo root) |
| Cursor | `.cursor/mcp.json` |

### Required MCPs — configure ONE AT A TIME

See [references/mcp-configs.md](references/mcp-configs.md) for per-tool config templates.

**1. Context7** (no credentials needed — just configure and move on)
- Add to MCP config for the user's tool(s)

**2. GitHub MCP** — requires a Personal Access Token. Use the ask tool:

> "GitHub MCP needs a Personal Access Token. Do you have one?"
> - Yes, I have a PAT ready
> - No, I need to create one

If **"Yes"**:
1. Tell user: "Please provide your GitHub PAT (paste it or tell me when you've added it to the config)"
2. **STOP AND WAIT** for user to provide the token
3. Use the ask tool: "Have you provided the GitHub PAT?"
4. Only after confirmation, write the MCP config with the token
5. Verify: `gh auth status` should show authenticated

If **"No"**:
1. Tell user: "Generate one at https://github.com/settings/tokens — select 'repo' scope"
2. **STOP AND WAIT** for user to create and provide the token
3. Continue as above once provided

**3. Laravel Boost** (API only, no credentials needed — just configure)
- Only configure if user selected API service

### Optional MCPs — ask ONE AT A TIME (based on Step 1 answers)

Only configure MCPs the user selected in Step 1.5. For each one that needs credentials, **STOP and WAIT** for the token.

**Lark MCP** (if selected):

Use the ask tool:
> "Lark MCP needs App ID and App Secret. Do you have them?"
> - Yes, I have them ready
> - No, I need to get them from arhen

If **"Yes"**:
1. Ask user: "Please provide the Lark App ID and App Secret"
2. **STOP AND WAIT** for user to provide both values
3. Use the ask tool: "Have you provided the Lark credentials?"
4. Only after confirmation, write the MCP config

If **"No"**:
1. Tell user: "Contact **arhen** for the Lark App ID and Secret"
2. Mark as pending — skip for now, can configure later

**Figma MCP** (if selected):

Use the ask tool:
> "Figma MCP needs a Personal Access Token. Do you have one?"
> - Yes, I have a token
> - No, I need to create one

If **"Yes"**:
1. Ask user: "Please provide your Figma access token"
2. **STOP AND WAIT** for user to provide the token
3. Use the ask tool: "Have you provided the Figma token?"
4. Only after confirmation, write the MCP config

If **"No"**:
1. Tell user: "Generate one at https://www.figma.com/developers/api#access-tokens"
2. **STOP AND WAIT** for user to create and provide the token
3. Continue as above once provided

**Sentry MCP** (if selected):
- Same pattern: ask for token → wait → configure

**IMPORTANT: Never write placeholder tokens like `<your-token>` into config files.** Either write the real token the user provided, or skip the MCP entirely. Placeholder tokens cause startup errors.

## Step 12: Verify & Complete — **STOP, ask user**

Before finishing, the agent MUST verify that everything works by starting all services.

Use the ask tool:

> "Everything is set up. Would you like me to start all services now to verify everything works?"
> - Yes, start all services
> - No, I'll do it later

### If user says Yes:

1. **Check for port conflicts first** (same ports as run-all.sh):
```bash
for port in 9191 3000 8000 9999 1025 8025; do
  pid=$(lsof -ti :$port 2>/dev/null)
  if [ -n "$pid" ]; then
    echo "⚠ Port $port in use by PID $pid — $(ps -p $pid -o comm= 2>/dev/null)"
  fi
done
```
If any ports are in use, ask user: "These ports are already in use (possibly from another workspace). Should I kill these processes?" Use the ask tool. Only kill after confirmation.

2. Run preflight: `./run-all.sh --check`
3. If preflight passes, start services: `./run-all.sh`
4. Wait 10-15 seconds for services to boot
5. Run health checks — **use the EXACT same checks as `./run-all.sh --status`:**

```bash
# API: check /api endpoint
api_code=$(curl -so /dev/null -w "%{http_code}" http://localhost:9191/api 2>/dev/null || echo "000")
[[ "$api_code" != "000" ]] && echo "✓ API (HTTP $api_code)" || echo "✗ API — down"

# Frontend
curl -sf http://localhost:3000 &>/dev/null && echo "✓ Frontend" || echo "✗ Frontend — down"

# AI Service
curl -sf http://localhost:8000/health &>/dev/null && echo "✓ AI Service" || echo "✗ AI Service — down"

# Data Service: 401 = auth-protected but running
data_code=$(curl -so /dev/null -w "%{http_code}" http://localhost:9999/api/v1/health/ 2>/dev/null || echo "000")
[[ "$data_code" == "200" || "$data_code" == "401" ]] && echo "✓ Data Service (HTTP $data_code)" || echo "✗ Data Service — down"

# Infrastructure
pg_isready -h localhost -p 5432 && echo "✓ PostgreSQL" || echo "✗ PostgreSQL — down"
redis-cli ping &>/dev/null && echo "✓ Redis" || echo "✗ Redis — down"

# Mailhog (optional)
curl -sf http://localhost:8025 &>/dev/null && echo "✓ Mailhog" || echo "○ Mailhog — not running (optional)"
```

5. **If ALL health checks pass:**
   - Tell user: "All services are running and healthy!"
   - Update `.onboard-state.json`: set `steps.verify` to `"completed"`

6. **If ANY health check fails:**
   - List which services failed and why (check logs: `tail .logs/<service>.log`)
   - Help troubleshoot:
     - Missing .env? → remind contact
     - Port conflict? → check what's using the port
     - DB not running? → start PostgreSQL
     - Missing deps? → re-run install
   - Use the ask tool: "Should I try to fix these issues?"
   - Keep trying until all services pass OR user decides to skip

7. **After verification, stop the services:**
   ```bash
   ./run-all.sh --stop
   ```

### Final summary

**Check for incomplete items.** Read `.onboard-state.json` and report:

If ALL critical steps are completed:
```
Onboarding complete! All services verified and working.

⚠ RESTART YOUR AGENT SESSION NOW

MCPs (Lark, Figma, GitHub, Context7) and skills (/workflow, /prd, etc.)
are loaded at session start. Since they were configured during this session,
you MUST restart for them to become active.

After restarting:
  /workflow start <feature-slug>    — begin a new feature
  /workflow status                  — check current state

Configured MCPs (available after restart):
  - Context7 — library documentation
  - GitHub — PR/issue management
  - Lark — PRD from Lark docs (if configured)
  - Figma — design specs (if configured)
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

  Failed health checks:
    - API — not responding (likely needs .env)

You can complete these later. When ready, run /onboard verify to re-check.
The workflow will block until all critical items are resolved.
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
