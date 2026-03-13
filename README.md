# frndOS — Workspace Setup & Development Guide

> **Version:** 1.0.0
> **Last Updated:** 2026-03-13
> **Maintainer:** Alva Intelligence Engineering

This file is the **onboarding guide** for setting up a frndOS development workspace. An LLM agent reads this on the first session, runs interactive setup, and generates `AGENTS.md` — the compact reference for all subsequent sessions.

---

## For LLM Agents — First-Time Onboarding

> **IMPORTANT:** Before starting, check if onboarding was already completed:
>
> ```bash
> if [ -f AGENTS.md ] && [ ! -L AGENTS.md ]; then
>     echo "Onboarding already completed. Read AGENTS.md instead."
> else
>     echo "First-time setup needed. Continue with onboarding below."
> fi
> ```
>
> If `AGENTS.md` exists as a **standalone file** (not a symlink to `README.md`), onboarding is done. **Read `AGENTS.md` and skip this file entirely.**

If you're an LLM Agent helping set up a frndOS development workspace — welcome! You'll guide the user through workspace configuration, prerequisite checks, model verification, and service setup.

> **INTERACTION MODEL — READ THIS FIRST:**
>
> This onboarding is **interactive**. You MUST follow these rules:
>
> 1. **Switch to plan mode first.** Before executing anything, switch to your CLI/editor's planning or interactive mode (e.g., Claude Code: plan mode, Cursor: chat, OpenCode: plan). This ensures you present plans and questions to the user and wait for their approval before executing.
> 2. **Execute steps in order** (Step 0 → Step 10). Do NOT skip ahead.
> 3. **Steps marked with ⛔ STOP** require user input. You MUST present the questions, then **stop and wait for the user's response** before continuing to the next step. Do NOT assume answers or proceed without them.
> 4. **Only run setup for services/tools the user selected.** Do not set up everything by default.
> 5. After each step completes, briefly summarize what was done before moving to the next step.

### Step 0: Verify GitHub access

Before anything else, verify the user has access to GitHub and the frndOS repositories. This prevents failures later when cloning.

#### Check gh CLI installation and authentication

```bash
# Check if gh CLI is installed
if command -v gh &>/dev/null; then
    echo "✓ GitHub CLI (gh) is installed: $(gh --version | head -1)"
else
    echo "✗ GitHub CLI (gh) is NOT installed — required"
    echo "Install from: https://cli.github.com/"
    exit 1
fi

# Check if user is authenticated
echo "Checking GitHub authentication..."
if gh auth status &>/dev/null; then
    echo "✓ GitHub CLI is authenticated"
    gh auth status 2>&1 | grep -E "(Logged in to|Token scopes)" || true
else
    echo "✗ GitHub CLI is NOT authenticated"
    echo "Run: gh auth login"
    exit 1
fi
```

#### Verify repository access

Check access to each repository. The user must have access to the `alva-intelligence` organization:

```bash
# Verify org access
echo "Checking alva-intelligence organization access..."
if gh api user/orgs --jq '.[].login' | grep -q "alva-intelligence"; then
    echo "✓ User has access to alva-intelligence organization"
else
    echo "⚠ Warning: User may not have access to alva-intelligence organization"
    echo "  Contact arhen to get invited to the organization"
fi

# Check specific repo access (these will fail with 404 if no access)
echo ""
echo "Checking repository access..."

# API repo
if gh repo view alva-intelligence/frnd-api-php &>/dev/null; then
    echo "✓ frnd-api-php (API): Access confirmed"
else
    echo "✗ frnd-api-php (API): No access — contact arhen"
fi

# Web repo
if gh repo view alva-intelligence/frnd-web &>/dev/null; then
    echo "✓ frnd-web (Frontend): Access confirmed"
else
    echo "✗ frnd-web (Frontend): No access — contact fahrizky or daffa"
fi

# AI Service repo
if gh repo view alva-intelligence/frnd-ai-services &>/dev/null; then
    echo "✓ frnd-ai-services (AI): Access confirmed"
else
    echo "✗ frnd-ai-services (AI): No access — contact rifki"
fi

# Data Service repo
if gh repo view alva-intelligence/frnd-clickhouse-api &>/dev/null; then
    echo "✓ frnd-clickhouse-api (Data): Access confirmed"
else
    echo "✗ frnd-clickhouse-api (Data): No access — contact kemal or iru"
fi
```

If any repository access is missing, **do not proceed** with cloning that service. The user must contact the owner to get access first.

#### Check Git configuration

```bash
# Verify git is configured
git config --global user.name || echo "⚠ Git user.name not set"
git config --global user.email || echo "⚠ Git user.email not set"
```

If git user.name or user.email is not set, help the user configure it:

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### Step 1: Ask user about their setup

> **⛔ STOP — This step requires user input.**
> Present ALL four questions below to the user in a single message, then **stop and wait** for their answers.
> Do NOT proceed to Step 2 until the user has responded.
> Do NOT assume default answers or make choices on behalf of the user.

Ask the user these questions to determine what to configure:

#### 1.1 Which services will you work on?

| # | Service | Directory | Stack |
|---|---|---|---|
| 1 | **API** | `api/` | Laravel 12, PHP 8.2+, PostgreSQL, Sanctum + JWT, Xendit, AWS S3 |
| 2 | **Frontend** | `web/` | Next.js 16, React 19, TypeScript, Tailwind CSS, Zustand, TanStack Query v5, Bun |
| 3 | **AI Service** | `ai-service/` | FastAPI, Python, Agno framework, OpenAI/Anthropic/Google, pgvector, Redis |
| 4 | **Data Service** | `data-service/` | FastAPI, Python, ClickHouse, pandas, Sentry |

#### 1.2 Do you have `.env` files ready?

Each service requires a `.env` file with secrets (database credentials, API keys, etc.). These are **never committed to git**. If the user doesn't have them, they must contact the service owner:

| Service | `.env` location | Contact for credentials |
|---|---|---|
| API | `api/.env` | **arhen** |
| Frontend | `web/.env.local` | **fahrizky**, **daffa** |
| AI Service | `ai-service/.env` | **rifki** |
| Data Service | `data-service/.env` | **kemal**, **iru** |

> **Do not proceed with service setup** for any service where the user doesn't have the `.env` file. The service won't run without it.

#### 1.3 Which editor/CLI do you use?

This determines which symlinks, MCP configs, and skills to set up.

**Editors:**
- **Cursor** — deep AI integration, multi-file editing, inline chat
- **Zed** — fast, lightweight, multiplayer
- **Antigravity** — AI-native editor

**CLI Agents:**
- **Claude Code** — best for complex multi-service tasks, strong tool use (primary recommendation)
- **OpenCode** — lightweight, fast, configurable
- **Codex** — OpenAI-native code generation

#### 1.4 Which AI provider subscriptions do you have?

Ask which providers the user has active subscriptions for. This determines model recommendations and what to verify in Step 3 (Verify model access).

- **Anthropic** (Claude Pro/Max)
  - Do you have access to **Claude Opus 4.6**? (best for planning, architecture, code review)
  - Do you have access to **Claude Sonnet 4.6**? (best for implementation tasks)
- **OpenAI** (ChatGPT Plus/Pro)
  - Do you have access to **GPT 5.3-codex**? (deep coding powerhouse)
  - Do you have access to **GPT 5.4**? (high intelligence, exploratory tasks)

**Preferred models for frndOS development:**

| Task | Preferred Model | Fallback |
|---|---|---|
| Planning & architecture | Claude Opus 4.6 | GPT 5.4 |
| Implementation & coding | Claude Sonnet 4.6 | GPT 5.3-codex |
| Code review | Claude Opus 4.6 | Claude Sonnet 4.6 |
| Exploratory / creative | GPT 5.4 | Claude Sonnet 4.6 |

### Step 2: Check system prerequisites

> **Switch to execution mode now.** The user has answered all questions. Exit plan mode and switch to your CLI/editor's execution or build mode (e.g., Claude Code: normal mode, Cursor: agent, OpenCode: build). All remaining steps (2–10) require executing commands.

> **Create a todo checklist now.** Based on the user's answers from Step 1, create a todo list covering Steps 2–10. Only include items relevant to the services, tools, and providers the user selected. Example:
>
> ```
> - [ ] Check system prerequisites (php, bun, python3, ...)
> - [ ] Verify model access (Claude Opus 4.6, Sonnet 4.6, ...)
> - [ ] Clone repositories (api, web, ...)
> - [ ] Install dependencies — api (composer install, migrate)
> - [ ] Install dependencies — web (bun install)
> - [ ] Create run-all.sh
> - [ ] Set up service documentation (docs/prd, docs/tracks)
> - [ ] Configure editor tooling — symlinks (Claude Code → CLAUDE.md)
> - [ ] Configure editor tooling — install skills
> - [ ] Configure editor tooling — MCP servers
> - [ ] Generate AGENTS.md
> - [ ] Verify and restart
> ```
>
> Adapt this list based on the user's selections. Skip items for services/tools the user didn't choose. Mark each item as you complete it.

Run these checks on the user's system. Only check tools relevant to the services the user selected.

> **These checks can be run in parallel using sub-agents.** Each tool category (runtimes, package managers, databases, dev tools, optional) can be checked independently and concurrently.

```bash
echo "=== Required Runtimes ==="
for cmd in php bun python3 node; do
    if command -v "$cmd" &>/dev/null; then
        echo "✓ $cmd: $("$cmd" --version 2>/dev/null | head -1)"
    else
        echo "✗ $cmd: NOT FOUND — required"
    fi
done

echo ""
echo "=== Package Managers ==="
for cmd in composer uv pip npm; do
    if command -v "$cmd" &>/dev/null; then
        echo "✓ $cmd: found"
    else
        echo "✗ $cmd: NOT FOUND — needed for dependency installation"
    fi
done

echo ""
echo "=== Databases ==="
for cmd in psql postgres; do
    if command -v "$cmd" &>/dev/null; then
        echo "✓ $cmd: found"
        break
    fi
done
if ! command -v psql &>/dev/null && ! command -v postgres &>/dev/null; then
    echo "✗ PostgreSQL: NOT FOUND — required for API and AI Service"
fi

echo ""
echo "=== Dev Tools ==="
for cmd in git gh; do
    if command -v "$cmd" &>/dev/null; then
        echo "✓ $cmd: found"
    else
        echo "✗ $cmd: NOT FOUND — required"
    fi
done

echo ""
echo "=== Optional Tools ==="
for cmd in ngrok; do
    if command -v "$cmd" &>/dev/null; then
        echo "✓ $cmd: found (for demo sharing)"
    else
        echo "○ $cmd: not found (optional — for sharing demos via PR)"
    fi
done

echo ""
echo "=== Service-Specific Tools ==="
# Mailhog for API email testing
if command -v mailhog &>/dev/null || docker ps --format "table {{.Names}}" | grep -q "mailhog"; then
    echo "✓ Mailhog: found (for API email testing)"
else
    echo "○ Mailhog: not found (optional — only needed for API email testing)"
    echo "  Install: brew install mailhog  OR  docker run -d -p 1025:1025 -p 8025:8025 mailhog/mailhog"
fi
```

If any **required** tool is missing, help the user install it before continuing.

### Step 3: Verify model access

Based on the user's CLI choice and AI subscriptions from Step 1, verify that the preferred models are actually accessible. This prevents surprises mid-session.

#### If using Claude Code

```bash
# Check Claude Code is installed
command -v claude &>/dev/null && echo "✓ Claude Code installed" || echo "✗ Claude Code not found"
```

Test each model the user claims to have access to:

```bash
# Test Claude Opus 4.6
echo "respond with just the word OK" | claude -p --model claude-opus-4-6 2>&1 | head -1

# Test Claude Sonnet 4.6
echo "respond with just the word OK" | claude -p --model claude-sonnet-4-6 2>&1 | head -1
```

If a model test fails (error or timeout), inform the user:
- They may not have the subscription tier required
- They should check their API keys / authentication
- Suggest falling back to a model that works

#### If using OpenCode

```bash
# Check OpenCode is installed
command -v opencode &>/dev/null && echo "✓ OpenCode installed: $(opencode --version 2>/dev/null)" || echo "✗ OpenCode not found"
```

Check which providers are authenticated and which models are available:

```bash
# List authenticated providers
opencode auth list

# List all available models (from configured providers)
opencode models

# Filter by provider
opencode models anthropic
opencode models openai
```

Test each model the user claims to have access to using `opencode run` (non-interactive mode):

```bash
# Test Claude Opus 4.6 (model format: provider/model)
opencode run -m anthropic/claude-opus-4-6 "respond with just the word OK" 2>&1 | head -5

# Test Claude Sonnet 4.6
opencode run -m anthropic/claude-sonnet-4-6 "respond with just the word OK" 2>&1 | head -5

# Test GPT 5.3-codex (if user has OpenAI)
opencode run -m openai/gpt-5.3-codex "respond with just the word OK" 2>&1 | head -5

# Test GPT 5.4 (if user has OpenAI)
opencode run -m openai/gpt-5.4 "respond with just the word OK" 2>&1 | head -5
```

> **Note:** OpenCode model format is `provider/model` (e.g., `anthropic/claude-opus-4-6`). Use `opencode models --refresh` to update the cached model list if new models aren't showing.

If a provider isn't authenticated yet, help the user set it up:

```bash
# Interactive provider login
opencode auth login
# User selects provider → follows OAuth or API key flow
```

#### If using Codex

```bash
# Check Codex is installed
command -v codex &>/dev/null && echo "✓ Codex installed" || echo "✗ Codex not found"
```

Codex uses OpenAI models natively. Verify the user's OpenAI API key is configured in their environment (`OPENAI_API_KEY`).

#### Report results

After testing, summarize which models are accessible and which failed. If the preferred models (Opus 4.6, Sonnet 4.6) are not available, recommend the best available alternative from the user's working models.

### Step 4: Clone repositories

Check which service directories exist. Clone only the services the user selected in Step 0.

> **Execute these clones in parallel using multiple agents** if your tool supports it. Each clone is independent and can run concurrently to speed up setup.

```bash
# API
[ -d "api" ] || (git clone git@github.com:alva-intelligence/frnd-api-php.git api && cd api && git checkout develop && cd ..)

# Frontend
[ -d "web" ] || (git clone https://github.com/alva-intelligence/frnd-web web && cd web && git checkout develop && cd ..)

# AI Service
[ -d "ai-service" ] || (git clone https://github.com/alva-intelligence/frnd-ai-services ai-service && cd ai-service && git checkout development && cd ..)

# Data Service
[ -d "data-service" ] || (git clone git@github.com:alva-intelligence/frnd-clickhouse-api.git data-service && cd data-service && git checkout development && cd ..)
```

### Step 5: Install service dependencies

For each service the user selected, install dependencies. **Skip any service where the user doesn't have the `.env` file.**

> **Dependency installation can be done in parallel using sub-agents.** Each service's setup is independent and can run concurrently (especially since each service has its own virtual environment or node_modules).

#### API (`api/`)

```bash
cd api
composer install
cp .env.example .env
php artisan key:generate
php artisan migrate
cd ..
```

Then ask the user to replace `api/.env` with the real credentials from **arhen**.

#### Database Setup (API)

After setting up the `.env` file, the user also needs a database dump for local development. Ask the user to request a **sanitized/dev database dump** from **arhen**.

Once they have the dump file (e.g., `frnd-dev-2025-03-13.dump`), they should:

1. Ensure PostgreSQL is running and the database exists (create it if needed):
   ```bash
   createdb frnd   # or whatever DB name is in api/.env
   ```

2. Restore the dump:
   ```bash
   psql frnd < ~/Downloads/frnd-dev-2025-03-13.dump
   ```

> **Note:** The dump should be a development/sanitized version without real user data or production secrets. Never request or use production dumps locally.

#### Frontend (`web/`)

```bash
cd web
bun install
cp .env.example .env.local
cd ..
```

Then ask the user to replace `web/.env.local` with the real credentials from **fahrizky** or **daffa**.

#### AI Service (`ai-service/`)

```bash
cd ai-service
pip install uv          # if not already installed
uv venv
uv pip install -r requirements.txt
cp .env.example .env
cd ..
```

Then ask the user to replace `ai-service/.env` with the real credentials from **rifki**.

#### Data Service (`data-service/`)

```bash
cd data-service
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
cd ..
```

Then ask the user to replace `data-service/.env` with the real credentials from **kemal** or **iru**.

### Step 6: Create `run-all.sh`

If `run-all.sh` does not exist in the `frnd/` parent directory, create it with the following content and make it executable:

<details>
<summary><strong>Full <code>run-all.sh</code> script (click to expand)</strong></summary>

```bash
#!/usr/bin/env bash
# run-all.sh — Start all frndOS services concurrently
# Usage: ./run-all.sh [--stop] [--status] [--check]
#
# Before first run, each service must be set up per its README:
#   api/           → composer install, cp .env.example .env, php artisan key:generate, php artisan migrate
#   web/           → bun install, cp .env.example .env.local
#   ai-service/    → uv venv && uv pip install -r requirements.txt, cp .env.example .env
#   data-service/  → python3 -m venv venv && pip install -r requirements.txt, cp .env.example .env
#
# Environment files (.env) contain secrets and are NOT committed to git.
# Contact the repo owner to get the correct .env for each service:
#   api/           → arhen
#   web/           → fahrizky, daffa
#   ai-service/    → rifki
#   data-service/  → kemal, iru

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$SCRIPT_DIR/.pids"
LOG_DIR="$SCRIPT_DIR/.logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

mkdir -p "$PID_DIR" "$LOG_DIR"

# ─── Helpers ──────────────────────────────────────────────────────────────────

log_info()  { echo -e "${BLUE}[info]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[ok]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[warn]${NC}  $1"; }
log_err()   { echo -e "${RED}[error]${NC} $1"; }

save_pid() {
  local name="$1" pid="$2"
  echo "$pid" > "$PID_DIR/$name.pid"
}

read_pid() {
  local name="$1"
  local pid_file="$PID_DIR/$name.pid"
  if [[ -f "$pid_file" ]]; then
    cat "$pid_file"
  fi
}

is_running() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ─── Preflight Checks ────────────────────────────────────────────────────────

preflight() {
  echo ""
  echo -e "  ${BOLD}frndOS — Preflight Checks${NC}"
  echo "  ────────────────────────"
  echo ""

  local errors=0
  local missing_envs=()

  # ── Global commands ───────────────────────────────────────────────────────

  local required_cmds=("php" "bun" "python3")
  for cmd in "${required_cmds[@]}"; do
    if command -v "$cmd" &>/dev/null; then
      log_ok "$cmd found ($(command -v "$cmd"))"
    else
      log_err "$cmd is not installed or not in PATH"
      errors=$((errors + 1))
    fi
  done

  echo ""

  # ── 1. API (api/) ────────────────────────────────────────────────────────

  log_info "Checking api/ ..."

  if [[ ! -d "$SCRIPT_DIR/api" ]]; then
    log_err "Directory 'api/' not found"
    log_warn "Run: git clone git@github.com:alva-intelligence/frnd-api-php.git api"
    errors=$((errors + 1))
  else
    if [[ -d "$SCRIPT_DIR/api/vendor" ]]; then
      log_ok "api/vendor/ exists (dependencies installed)"
    else
      log_err "api/vendor/ missing — run: cd api && composer install"
      errors=$((errors + 1))
    fi

    if [[ -f "$SCRIPT_DIR/api/.env" ]]; then
      log_ok "api/.env exists"
    else
      log_err "api/.env missing"
      missing_envs+=("api/ → contact arhen")
      errors=$((errors + 1))
    fi
  fi

  echo ""

  # ── 2. Frontend (web/) ───────────────────────────────────────────────────

  log_info "Checking web/ ..."

  if [[ ! -d "$SCRIPT_DIR/web" ]]; then
    log_err "Directory 'web/' not found"
    log_warn "Run: git clone https://github.com/alva-intelligence/frnd-web web"
    errors=$((errors + 1))
  else
    if [[ -d "$SCRIPT_DIR/web/node_modules" ]]; then
      log_ok "web/node_modules/ exists (dependencies installed)"
    else
      log_err "web/node_modules/ missing — run: cd web && bun install"
      errors=$((errors + 1))
    fi

    if [[ -f "$SCRIPT_DIR/web/.env.local" ]] || [[ -f "$SCRIPT_DIR/web/.env" ]]; then
      log_ok "web/.env exists"
    else
      log_err "web/.env.local missing"
      missing_envs+=("web/ → contact fahrizky or daffa")
      errors=$((errors + 1))
    fi
  fi

  echo ""

  # ── 3. AI Service (ai-service/) ──────────────────────────────────────────

  log_info "Checking ai-service/ ..."

  if [[ ! -d "$SCRIPT_DIR/ai-service" ]]; then
    log_err "Directory 'ai-service/' not found"
    log_warn "Run: git clone https://github.com/alva-intelligence/frnd-ai-services ai-service"
    errors=$((errors + 1))
  else
    if [[ -f "$SCRIPT_DIR/ai-service/.venv/bin/activate" ]]; then
      log_ok "ai-service/.venv/ exists (virtual environment ready)"
    else
      log_err "ai-service/.venv/ missing — run: cd ai-service && uv venv && uv pip install -r requirements.txt"
      errors=$((errors + 1))
    fi

    if [[ -f "$SCRIPT_DIR/ai-service/.env" ]]; then
      log_ok "ai-service/.env exists"
    else
      log_err "ai-service/.env missing"
      missing_envs+=("ai-service/ → contact rifki")
      errors=$((errors + 1))
    fi
  fi

  echo ""

  # ── 4. Data Service (data-service/) ──────────────────────────────────────

  log_info "Checking data-service/ ..."

  if [[ ! -d "$SCRIPT_DIR/data-service" ]]; then
    log_err "Directory 'data-service/' not found"
    log_warn "Run: git clone git@github.com:alva-intelligence/frnd-clickhouse-api.git data-service"
    errors=$((errors + 1))
  else
    if [[ -f "$SCRIPT_DIR/data-service/venv/bin/activate" ]]; then
      log_ok "data-service/venv/ exists (virtual environment ready)"
    else
      log_err "data-service/venv/ missing — run: cd data-service && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt"
      errors=$((errors + 1))
    fi

    if [[ -f "$SCRIPT_DIR/data-service/.env" ]]; then
      log_ok "data-service/.env exists"
    else
      log_err "data-service/.env missing"
      missing_envs+=("data-service/ → contact kemal or iru")
      errors=$((errors + 1))
    fi
  fi

  echo ""

  # ── Summary ──────────────────────────────────────────────────────────────

  if [[ ${#missing_envs[@]} -gt 0 ]]; then
    echo "  ────────────────────────────────────────────────"
    echo -e "  ${BOLD}Missing .env files — contact the repo owner:${NC}"
    echo ""
    for entry in "${missing_envs[@]}"; do
      echo -e "    ${YELLOW}●${NC} $entry"
    done
    echo ""
    echo -e "  ${DIM}.env files contain secrets (DB passwords, API keys, etc.)${NC}"
    echo -e "  ${DIM}They are never committed to git. Ask the owner for a copy.${NC}"
    echo "  ────────────────────────────────────────────────"
    echo ""
  fi

  if [[ $errors -gt 0 ]]; then
    log_err "Preflight failed with $errors issue(s). Fix them before running services."
    echo ""
    return 1
  else
    log_ok "All preflight checks passed."
    echo ""
    return 0
  fi
}

# ─── Stop all services ────────────────────────────────────────────────────────

stop_all() {
  log_info "Stopping all services..."
  local stopped=0

  for pid_file in "$PID_DIR"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    local name
    name="$(basename "$pid_file" .pid)"
    local pid
    pid="$(cat "$pid_file")"

    if is_running "$pid"; then
      kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      log_ok "Stopped $name (PID $pid)"
      stopped=$((stopped + 1))
    else
      log_warn "$name was not running (stale PID $pid)"
    fi
    rm -f "$pid_file"
  done

  if [[ $stopped -eq 0 ]]; then
    log_info "No running services found."
  else
    log_ok "Stopped $stopped service(s)."
  fi
}

# ─── Status check ─────────────────────────────────────────────────────────────

status_all() {
  echo ""
  echo "  frndOS Service Status"
  echo "  ─────────────────────"
  echo ""

  local services=("api-server" "api-queue" "web" "ai-service" "data-service")
  local labels=("API Server" "API Queue Worker" "Frontend (web)" "AI Service" "Data Service")
  local any_running=false

  for i in "${!services[@]}"; do
    local name="${services[$i]}"
    local label="${labels[$i]}"
    local pid
    pid="$(read_pid "$name")"

    if [[ -n "$pid" ]] && is_running "$pid"; then
      echo -e "  ${GREEN}●${NC} $label  (PID $pid)"
      any_running=true
    else
      echo -e "  ${RED}○${NC} $label"
      rm -f "$PID_DIR/$name.pid" 2>/dev/null
    fi
  done

  echo ""

  if $any_running; then
    echo "  Logs: $LOG_DIR/"
    echo "  Stop: ./run-all.sh --stop"
  else
    echo "  No services running. Start with: ./run-all.sh"
  fi
  echo ""
}

# ─── Start all services ───────────────────────────────────────────────────────

start_all() {
  if ! preflight; then
    exit 1
  fi

  echo -e "  ${BOLD}frndOS — Starting all services${NC}"
  echo "  ──────────────────────────────"
  echo ""

  local failed=0

  # ── 1. API Server (php artisan serve) ─────────────────────────────────────

  log_info "Starting API server..."
  local api_pid
  api_pid="$(read_pid "api-server")"
  if [[ -n "$api_pid" ]] && is_running "$api_pid"; then
    log_warn "API server already running (PID $api_pid)"
  else
    (cd "$SCRIPT_DIR/api" && php artisan serve --port=9191) \
      > "$LOG_DIR/api-server.log" 2>&1 &
    save_pid "api-server" $!
    log_ok "API server started (PID $!) → http://localhost:9191"
  fi

  # ── 2. API Queue Worker ───────────────────────────────────────────────────

  log_info "Starting API queue worker..."
  local queue_pid
  queue_pid="$(read_pid "api-queue")"
  if [[ -n "$queue_pid" ]] && is_running "$queue_pid"; then
    log_warn "API queue worker already running (PID $queue_pid)"
  else
    (cd "$SCRIPT_DIR/api" && php artisan queue:work database \
      --timeout=3000 --tries=5 --queue=high,low,default,subscriptions) \
      > "$LOG_DIR/api-queue.log" 2>&1 &
    save_pid "api-queue" $!
    log_ok "API queue worker started (PID $!)"
  fi

  # ── 3. Frontend (bun dev) ─────────────────────────────────────────────────

  log_info "Starting Frontend..."
  local web_pid
  web_pid="$(read_pid "web")"
  if [[ -n "$web_pid" ]] && is_running "$web_pid"; then
    log_warn "Frontend already running (PID $web_pid)"
  else
    (cd "$SCRIPT_DIR/web" && bun dev) \
      > "$LOG_DIR/web.log" 2>&1 &
    save_pid "web" $!
    log_ok "Frontend started (PID $!) → http://localhost:3000"
  fi

  # ── 4. AI Service (activate venv + fastapi dev) ───────────────────────────

  log_info "Starting AI Service..."
  local ai_pid
  ai_pid="$(read_pid "ai-service")"
  if [[ -n "$ai_pid" ]] && is_running "$ai_pid"; then
    log_warn "AI Service already running (PID $ai_pid)"
  else
    (cd "$SCRIPT_DIR/ai-service" && source .venv/bin/activate && fastapi dev) \
      > "$LOG_DIR/ai-service.log" 2>&1 &
    save_pid "ai-service" $!
    log_ok "AI Service started (PID $!) → http://localhost:8000"
  fi

  # ── 5. Data Service (activate venv + uvicorn) ────────────────────────────

  log_info "Starting Data Service..."
  local data_pid
  data_pid="$(read_pid "data-service")"
  if [[ -n "$data_pid" ]] && is_running "$data_pid"; then
    log_warn "Data Service already running (PID $data_pid)"
  else
    (cd "$SCRIPT_DIR/data-service" && source venv/bin/activate && \
      uvicorn app.main:app --reload --port 9999) \
      > "$LOG_DIR/data-service.log" 2>&1 &
    save_pid "data-service" $!
    log_ok "Data Service started (PID $!) → http://localhost:9999"
  fi

  # ── Summary ───────────────────────────────────────────────────────────────

  echo ""
  echo "  ──────────────────────────────"
  log_ok "All services started."
  echo ""
  echo "  Endpoints:"
  echo "    API Server    → http://localhost:9191"
  echo "    Frontend      → http://localhost:3000"
  echo "    AI Service    → http://localhost:8000"
  echo "    Data Service  → http://localhost:9999"
  echo ""
  echo "  Logs:    tail -f $LOG_DIR/<service>.log"
  echo "  Status:  ./run-all.sh --status"
  echo "  Stop:    ./run-all.sh --stop"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --stop)
    stop_all
    ;;
  --status)
    status_all
    ;;
  --check)
    preflight
    ;;
  --help|-h)
    echo ""
    echo "  Usage: ./run-all.sh [command]"
    echo ""
    echo "  Commands:"
    echo "    (no args)   Run preflight checks, then start all services in background"
    echo "    --check     Run preflight checks only (do not start services)"
    echo "    --status    Show status of all services"
    echo "    --stop      Stop all running services"
    echo "    --help      Show this help message"
    echo ""
    echo "  First-time setup:"
    echo "    Each service must be set up per its README before running."
    echo "    You also need the .env file for each service from its owner:"
    echo ""
    echo "    api/           → arhen"
    echo "    web/           → fahrizky, daffa"
    echo "    ai-service/    → rifki"
    echo "    data-service/  → kemal, iru"
    echo ""
    ;;
  *)
    start_all
    ;;
esac
```

</details>

Then make it executable:

```bash
chmod +x run-all.sh
```

Verify it works:

```bash
./run-all.sh --check
```

#### `run-all.sh` usage

```bash
./run-all.sh            # Start all services (runs preflight first)
./run-all.sh --check    # Preflight checks only
./run-all.sh --status   # Check what's running
./run-all.sh --stop     # Stop all services
```

| Process | Command | Port | Log |
|---|---|---|---|
| API Server | `php artisan serve --port=9191` | 9191 | `.logs/api-server.log` |
| API Queue | `php artisan queue:work database --timeout=3000 --tries=5 --queue=high,low,default,subscriptions` | — | `.logs/api-queue.log` |
| Frontend | `bun dev` | 3000 | `.logs/web.log` |
| AI Service | `source .venv/bin/activate && fastapi dev` | 8000 | `.logs/ai-service.log` |
| Data Service | `source venv/bin/activate && uvicorn app.main:app --reload --port 9999` | 9999 | `.logs/data-service.log` |

### Step 7: Set up service documentation

For each service the user selected, create the documentation folder structure and ensure the service's `AGENTS.md` includes documentation conventions.

#### 7.1 Create docs folders

```bash
for dir in api web ai-service data-service; do
    [ -d "$dir" ] || continue
    mkdir -p "$dir/docs/prd"
    mkdir -p "$dir/docs/tracks"
done
```

#### 7.2 Append documentation conventions to service AGENTS.md

For each service that has an existing `AGENTS.md`, check if it already contains a documentation section. If not, append the full documentation conventions so every agent session in that service knows the rules.

Check and append for each service:

```bash
for dir in api web ai-service data-service; do
    [ -f "$dir/AGENTS.md" ] || continue
    # Only append if not already present
    grep -q "## Documentation Structure" "$dir/AGENTS.md" && continue
    echo "Appending documentation conventions to $dir/AGENTS.md"
done
```

For each service where the check above says "Appending...", append the following block to the end of that service's `AGENTS.md`:

````markdown

---

## Documentation Structure

This service maintains a `docs/` folder with the following structure:

```
docs/
├── prd/                         ← Product Requirement Documents
│   └── <feature-name>.md
└── tracks/                      ← Tracking files (1:1 mapping with PRDs)
    └── <feature-name>.track.md
```

**Rules:**
- `docs/prd/` — PRD files only. Clean, self-describing documents.
- `docs/tracks/` — tracking files only. One per PRD, same base name with `.track.md` suffix.
- PRD files must **never** contain task tracking or progress checklists. That belongs in the tracking file.

### PRD File Format

Naming: `docs/prd/<feature-name>.md` (kebab-case, self-explaining)

Every PRD starts with YAML frontmatter:

```markdown
---
title: Feature Name
created: YYYY-MM-DD
creator: <name>
workers:
  - <name>
status: draft              # draft | in-progress | completed | archived
service: <service>         # api | web | ai-service | data-service | cross-service
priority: medium           # low | medium | high | critical
---
```

Template sections: Objective, Background, Requirements (Functional + Non-Functional), Scope (In/Out), Technical Approach, API Contracts, UI/UX, Dependencies, Success Criteria, Open Questions.

### Tracking File Format

Naming: `docs/tracks/<feature-name>.track.md` (must match PRD base name)

Every tracking file starts with:

```markdown
---
prd: <feature-name>
last_updated: YYYY-MM-DD
updated_by: <name>
---
```

Template sections: Status Summary (table), Milestones (with checklists), Decisions Log (table), Blockers, Notes.
````

> **Important:** Only append if the service's `AGENTS.md` exists and doesn't already have this section. Do not create a new `AGENTS.md` for a service — that is the service owner's responsibility.

### Step 8: Configure editor/agent tooling

Based on the user's editor/CLI from Step 1:

#### 8.1 Agent instruction symlinks

Create symlinks **only for the tool(s) the user selected in Step 1**. Each tool reads a different filename:

| Tool | Expected File | Symlink Command |
|---|---|---|
| **Claude Code** | `CLAUDE.md` | `ln -sf AGENTS.md CLAUDE.md` |
| **Cursor** | `.cursorrules` | `ln -sf AGENTS.md .cursorrules` |
| **GitHub Copilot** | `.github/copilot-instructions.md` | `mkdir -p .github && ln -sf ../AGENTS.md .github/copilot-instructions.md` |
| **OpenCode** | `AGENTS.md` (native) | No symlink needed |

Run only the relevant symlink commands for each service the user works on. For example, if the user chose **Claude Code**:

```bash
for dir in api web ai-service data-service; do
    [ -d "$dir" ] || continue
    cd "$dir"

    # Claude Code reads CLAUDE.md
    [ -L CLAUDE.md ] || ln -sf AGENTS.md CLAUDE.md

    cd ..
done
```

If the user chose **Cursor**:

```bash
for dir in api web ai-service data-service; do
    [ -d "$dir" ] || continue
    cd "$dir"

    # Cursor reads .cursorrules
    [ -L .cursorrules ] || ln -sf AGENTS.md .cursorrules

    cd ..
done
```

If the user chose **GitHub Copilot** (in VS Code or other editor):

```bash
for dir in api web ai-service data-service; do
    [ -d "$dir" ] || continue
    cd "$dir"

    # GitHub Copilot reads .github/copilot-instructions.md
    mkdir -p .github
    [ -L .github/copilot-instructions.md ] || ln -sf ../AGENTS.md .github/copilot-instructions.md

    cd ..
done
```

> **Do NOT create all symlinks.** Only create the ones for the user's chosen tool(s). Extra symlinks clutter the repo and may confuse other tools.

#### 8.2 Install skills

Skills are installed via [skills.sh](https://skills.sh/). Install based on which services the user works on:

```bash
# Cross-service (always install)
npx skills add github/awesome-copilot/git-commit        # conventional commit messages
npx skills add github/awesome-copilot/prd                # PRD creation
```

If the user works on the **Frontend** (`web/`):

```bash
npx skills add anthropics/skills/frontend-design         # production-grade UI
npx skills add vercel-labs/agent-skills                   # react best practices
npx skills add vercel-labs/next-skills                    # next.js best practices
npx skills add busirocket/tailwindcss-v4                  # tailwind CSS v4
npx skills add radix-ui/design-system                     # accessible components
```

> Browse more skills at [skills.sh](https://skills.sh/) or use `npx skills add vercel-labs/skills/find-skills`.

#### 8.3 MCP configuration

Each tool reads MCP config from a different path. Configure for the user's tool:

| Tool | Config File |
|---|---|
| **Claude Code** | `.mcp.json` (repo root) |
| **OpenCode** | `opencode.json` (repo root) |
| **Cursor** | `.cursor/mcp.json` |
| **VS Code** | `.vscode/mcp.json` |

**Required MCPs** to configure:

| MCP Server | Purpose |
|---|---|
| **Context7** | Up-to-date documentation lookup for any library/framework |
| **GitHub** | PR management, issue tracking, repository operations |
| **Laravel Boost** | Laravel-specific docs, tinker, artisan, DB queries (API only) |

**Optional MCPs:**

| MCP Server | Purpose |
|---|---|
| **Sentry** | Error tracking and monitoring (production debugging) |
| **Figma** | Design-to-code translation (frontend design implementation) |

### Step 9: Generate `AGENTS.md`

Onboarding is almost complete. Now generate the `AGENTS.md` file that subsequent agent sessions will read.

1. Remove the existing `AGENTS.md` symlink (if it exists):

```bash
[ -L AGENTS.md ] && rm AGENTS.md
```

2. Write a new `AGENTS.md` file. The content should be everything between the `<!-- REFERENCE_START -->` and `<!-- REFERENCE_END -->` markers below, prefixed with this header:

```markdown
# frndOS — Agentic Development Guide

> Auto-generated by onboarding from README.md
> Generated: [current date]
>
> To re-run onboarding, delete this file and start a new agent session from the `frnd/` directory.
> The onboarding script is in README.md.

---
```

### Step 10: Verify and restart

Tell the user:

> **Onboarding complete!** Please restart your agent session now.
>
> From this point forward, the agent will automatically read `AGENTS.md` and have full project context without going through setup again.
>
> To re-run onboarding (e.g., after adding a new service or changing tools), delete `AGENTS.md` and start a new session.

---

<!-- REFERENCE_START -->

# A. Definitions

## A.1 What is frndOS?

> **TBD** — This section is pending formal product definition.

<!-- Placeholder: frndOS product vision, value proposition, and target users will be defined here. -->

---

## A.2 Architecture

### Overview

frndOS follows a **hub-and-spoke architecture** where the **API** acts as the central orchestration layer. All external-facing services (Frontend, AI, Data) communicate through the API, which owns authentication, authorization, business logic, and data persistence.

### Component Map

```
┌─────────────┐
│   Frontend   │  Next.js 16 / React 19
│    (web/)    │  Renders UI, consumes API
└──────┬───────┘
       │ ← (API → Frontend: data delivery)
       │
┌──────▼───────┐       ┌─────────────────┐
│              │◄─────►│       AI         │
│     API      │       │  (ai-service/)    │
│    (api/)    │       │  FastAPI + Agno  │
│              │       └─────────────────┘
│  Laravel 12  │
│  Central Hub │       ┌─────────────────┐
│              │──────►│  Data Warehouse  │
│              │       │  (ClickHouse)    │
└──────┬───────┘       └────────┬────────┘
       │                        │
       │ ◄─── bidirectional ──► │
       │                        │
┌──────▼───────┐       ┌───────▼─────────┐
│   Database   │       │  Data Platform   │
│ (PostgreSQL) │       │ (data-service/)  │
│              │       │                  │
└──────────────┘       └─────────────────┘
```

### Relationships

| Connection | Direction | Purpose |
|---|---|---|
| **API ↔ Database** | Bidirectional | Primary data persistence via Eloquent ORM. All CRUD, auth state, and business entities. |
| **API → Frontend** | Unidirectional | API serves data to frontend. Frontend never accesses DB, AI, or data services directly. |
| **API ↔ AI** | Bidirectional | API sends queries/context to AI, receives insights/responses. AI may call back for entity resolution. |
| **API → Data Warehouse** | Unidirectional | API pushes raw/processed data to ClickHouse for analytics. |
| **Data Warehouse ↔ Data Platform** | Bidirectional | Data Platform reads/writes ClickHouse. Analytics/BI query layer. |

### Why This Architecture?

1. **Single entry point** — API centralizes auth (Sanctum + JWT), authorization, and validation. No service exposed directly to frontend.
2. **Separation of concerns** — API owns business logic, AI owns intelligence, Data owns analytics, Frontend owns presentation.
3. **Independent scaling** — Each service deploys/scales independently. AI scales GPU without affecting API.
4. **Security boundary** — Sensitive operations (Xendit payments, S3 storage) isolated in API. Frontend never holds secrets.

---

## A.3 Services

### Service Registry

| # | Service | Directory | Repository | Default Branch | Stack |
|---|---|---|---|---|---|
| 1 | **API** | `api/` | `git@github.com:alva-intelligence/frnd-api-php.git` | `develop` | Laravel 12, PHP 8.2+, PostgreSQL, Sanctum + JWT, Xendit, AWS S3 |
| 2 | **Frontend** | `web/` | `https://github.com/alva-intelligence/frnd-web` | `develop` | Next.js 16, React 19, TypeScript, Tailwind CSS, Zustand, TanStack Query v5, Bun |
| 3 | **AI** | `ai-service/` | `https://github.com/alva-intelligence/frnd-ai-services` | `development` | FastAPI, Python, Agno framework, OpenAI/Anthropic/Google, pgvector, Redis |
| 4 | **Data** | `data-service/` | `git@github.com:alva-intelligence/frnd-clickhouse-api.git` | `development` | FastAPI, Python, ClickHouse, pandas, Sentry |

### Ownership

| Service | Owner(s) | Responsibility |
|---|---|---|
| API + Database | **arhen** | Backend logic, database schema, auth, payments, integrations |
| Frontend | **fahrizky**, **daffa** | UI/UX, client-side state, frontend performance |
| AI | **rifki** | AI agents, LLM orchestration, vector search, chat |
| Data | **kemal**, **iru** | Analytics pipelines, ClickHouse queries, data transformations |

---

# B. Agentic Workflow

## B.1 Session Protocol

Every agent session should perform these steps before writing any code:

1. **Read the service's `AGENTS.md`** — Each service has its own `AGENTS.md` with project-specific conventions. The agent **must** read and respect it for every service it will touch.

   ```
   # If working on the API:
   Read api/AGENTS.md

   # If working on the Frontend:
   Read web/AGENTS.md

   # If working across services:
   Read api/AGENTS.md, web/AGENTS.md, ai-service/AGENTS.md, data-service/AGENTS.md
   ```

   > Service-level `AGENTS.md` rules **override** this guide when there is a conflict.

2. **Start services** — Run `./run-all.sh` from the `frnd/` parent directory as a **background process within the agent session**. The services should run as long as the agent session is active and stop when the session ends.

   ```bash
   # Run as a foreground background process (tied to agent session lifetime)
   ./run-all.sh &
   ```

   If `run-all.sh` doesn't exist, create it from the content in `README.md` Step 6.

   > **Important:** Do NOT tell the user to run services in a separate terminal. The agent should start them directly. When the agent/CLI session exits, the processes terminate automatically.

## B.2 Working Directory Convention

**Always start sessions from the `frnd/` parent directory.** This gives the agent visibility across all services and enables cross-service reasoning.

When working on a single service, scope into that directory, but initial context gathering should happen at the parent level.

## B.3 Running All Services

Use `./run-all.sh` to manage services. If the script doesn't exist, create it from `README.md` Step 6.

```bash
./run-all.sh            # Start all (runs preflight first)
./run-all.sh --check    # Preflight checks only
./run-all.sh --status   # Check what's running
./run-all.sh --stop     # Stop all services
```

| Process | Command | Port | Log |
|---|---|---|---|
| API Server | `php artisan serve --port=9191` | 9191 | `.logs/api-server.log` |
| API Queue | `php artisan queue:work database --timeout=3000 --tries=5 --queue=high,low,default,subscriptions` | — | `.logs/api-queue.log` |
| Frontend | `bun dev` | 3000 | `.logs/web.log` |
| AI Service | `source .venv/bin/activate && fastapi dev` | 8000 | `.logs/ai-service.log` |
| Data Service | `source venv/bin/activate && uvicorn app.main:app --reload --port 9999` | 9999 | `.logs/data-service.log` |

## B.4 Contributing Guidelines

### Ownership & Review

- Every service has designated owner(s) (see [A.3 Ownership](#ownership)).
- All PRs **must be reviewed and merged by the service owner(s)**.
- Code review agents can provide automated review, but owner approval is required for merge.

### Branch Naming

```
feature/<short-description>    ← new functionality
fix/<short-description>        ← bug fixes
```

### Development Flow

```
1. Create branch from default branch
   git checkout -b feature/xxx

2. Develop and commit (conventional commits)
   git add . && git commit -m "feat: add brand health endpoint"

3. Push and create PR
   git push -u origin feature/xxx
   gh pr create --base develop --title "feat: add brand health endpoint"

4. Demo via ngrok (for cross-team review)
   API: ngrok http 9191 | Frontend: ngrok http 3000

5. PR review by service owner(s)

6. Merge into develop (API/Frontend) or development (AI/Data)
```

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add new brand analytics endpoint
fix: resolve token refresh race condition
refactor: extract shared query builder
docs: update API endpoint documentation
chore: upgrade dependencies
```

Do **NOT** add AI attribution footers to commits.

---

# C. Tools

## C.1 Models

| Provider | Models | Best For |
|---|---|---|
| **Anthropic** | Claude Opus 4.6, Claude Sonnet 4.6 | Complex reasoning, architecture, multi-file refactoring, code review |
| **OpenAI** | GPT 5.3-codex, GPT 5.4 | Code generation, rapid iteration, broad language support |

**Preferred models for frndOS:**

| Task | Preferred Model | Fallback |
|---|---|---|
| Planning & architecture | Claude Opus 4.6 | GPT 5.4 |
| Implementation & coding | Claude Sonnet 4.6 | GPT 5.3-codex |
| Code review | Claude Opus 4.6 | Claude Sonnet 4.6 |
| Exploratory / creative | GPT 5.4 | Claude Sonnet 4.6 |

## C.2 Editors

| Editor | Strengths | Notes |
|---|---|---|
| **Cursor** | Deep AI integration, multi-file editing, inline chat | Recommended for complex refactoring |
| **Antigravity** | Emerging AI-native editor | Good for experimentation |
| **Zed** | Fast, lightweight, multiplayer | Good for pair programming and quick edits |

## C.3 CLI Agents

| CLI | Strengths | Notes |
|---|---|---|
| **Claude Code** | Best for complex multi-service tasks, strong tool use | Primary recommendation for frndOS |
| **OpenCode** | Lightweight, fast, configurable | Good for single-service tasks |
| **Codex** | OpenAI-native, good for code generation | Alternative for GPT-preferred workflows |

## C.4 Skills

Skills are installed via **[skills.sh](https://skills.sh/)** using `npx skills add <owner/repo>`. The CLI installs to `~/.agents/skills/` and auto-symlinks to detected tool directories.

### Installing Skills from the Parent Directory

> **Important:** When the agent is running from the parent directory (where this README lives) and the user asks to install a skill, the agent **must ask which service(s)** the skill should apply to before installing. Skills are service-scoped — a frontend skill (e.g., `tailwindcss-v4`) should only be installed in `web/`, not in `api/`.
>
> 1. Ask: "Which service(s) should this skill be installed for?" (api, web, ai-service, data-service)
> 2. Install the skill globally: `npx skills add <owner/repo>`
> 3. If needed, create per-service symlinks or configuration to scope the skill

### Skills per Service

| Skill | Service(s) | Why |
|---|---|---|
| `git-commit` | all | Enforce conventional commit messages |
| `prd` | all | Standardized PRD creation |
| `frontend-design` | web | Production-grade UI component creation |
| `vercel-react-best-practices` | web | React 19 + Next.js 16 performance optimization |
| `next-best-practices` | web | Next.js app router patterns and caching |
| `busirocket-tailwindcss-v4` | web | Tailwind CSS v4 utility patterns |
| `radix-ui-design-system` | web | Accessible components (Radix UI) |
| `design-taste-frontend` | web | Senior-level UI/UX engineering |
| `frontend-security` | web | XSS, CSRF, DOM security audits |
| `typescript-security-review` | web | TypeScript-specific security review |
| `tanstack-query` | web | TanStack Query v5 patterns |

> **Python/FastAPI, ClickHouse, Laravel**: No dedicated skills yet. Use Context7 MCP for docs and Laravel Boost MCP for artisan/tinker/DB.

### Manual symlink (if auto-detect missed a tool)

```bash
# Claude Code
ln -sfn ../../.agents/skills/<skill> ~/.claude/skills/<skill>

# OpenCode (community skills)
ln -sfn ../../../.agents/skills/<skill> ~/.config/opencode/skills/<skill>
```

## C.5 MCP Servers

MCP configs **cannot be shared** across tools (different JSON formats). Each tool needs its own config file.

### Installing MCPs from the Parent Directory

> **Important:** When the agent is running from the parent directory (where this README lives) and the user asks to add an MCP server, the agent **must ask which service(s)** the MCP should be configured for. MCP configs are per-project (stored in the service's repo root), so a Laravel Boost MCP belongs in `api/`, not in `web/`.
>
> 1. Ask: "Which service(s) should this MCP be configured for?" (api, web, ai-service, data-service)
> 2. Determine which tool the user uses (Claude Code → `.mcp.json`, OpenCode → `opencode.json`, Cursor → `.cursor/mcp.json`)
> 3. Add the MCP config to the correct file **inside the selected service directory**

### Per-Tool Config Locations

| Tool | Global Config | Per-Project Config |
|---|---|---|
| **Claude Code** | `~/.claude/settings.json` | `.mcp.json` (repo root) |
| **OpenCode** | `~/.config/opencode/opencode.json` | `opencode.json` (repo root) |
| **Cursor** | Cursor Settings UI | `.cursor/mcp.json` |
| **VS Code** | VS Code Settings UI | `.vscode/mcp.json` |

### Required MCPs

| MCP Server | Purpose |
|---|---|
| **Context7** | Up-to-date documentation lookup for any library/framework |
| **GitHub** | PR management, issue tracking, repository operations |
| **Laravel Boost** | Laravel-specific docs, tinker, artisan, DB queries (API only) |

### Optional MCPs

| MCP Server | Purpose |
|---|---|
| **Sentry** | Error tracking and monitoring (production debugging) |
| **Figma** | Design-to-code translation (frontend design implementation) |

## C.6 Agent Configuration Files

`AGENTS.md` is the canonical agent instructions file. Symlink for tools that expect different filenames:

| Canonical | Tool-specific (symlinked) |
|---|---|
| `AGENTS.md` | `CLAUDE.md` → `AGENTS.md` (Claude Code) |
| | `.cursorrules` → `AGENTS.md` (Cursor) |
| | `.github/copilot-instructions.md` → `AGENTS.md` (Copilot) |
| | OpenCode reads `AGENTS.md` natively |

### Dot Folders Are for Settings Only

```
api/
├── .claude/                      ← Claude Code settings (permissions)
├── .cursor/                      ← Cursor settings (model prefs)
│   └── mcp.json                  ← Cursor MCP config
├── .vscode/                      ← VS Code settings
│   └── mcp.json                  ← VS Code MCP config
├── .mcp.json                     ← Claude Code MCP config
├── opencode.json                 ← OpenCode MCP config
├── AGENTS.md                     ← Agent instructions (THE source of truth)
├── CLAUDE.md → AGENTS.md         ← symlink
├── .cursorrules → AGENTS.md      ← symlink
├── .github/
│   └── copilot-instructions.md → ../AGENTS.md
└── docs/                         ← Documentation (PRDs, tracks)
```

**Rules:**
- Dot folders (`.claude/`, `.cursor/`, `.vscode/`) contain **only** tool settings
- These folders must **never** contain documentation, PRDs, or architectural notes
- All documentation goes in `docs/`

---

# D. Documentation

## D.1 Structure

Each service repository should maintain:

```
<service>/
├── docs/
│   ├── prd/                         ← Product Requirement Documents
│   │   ├── brand-health-dashboard.md
│   │   └── ask-frnd-v2.md
│   └── tracks/                      ← Tracking files (1:1 mapping with PRDs)
│       ├── brand-health-dashboard.track.md
│       └── ask-frnd-v2.track.md
├── AGENTS.md
└── ...
```

**Rules:**
- `docs/prd/` — PRD files only. Clean, self-describing documents.
- `docs/tracks/` — tracking files only. One per PRD, same base name + `.track.md` suffix.
- PRD files must **never** contain task tracking or progress checklists.

## D.2 PRD Files

PRD files describe **what** to build and **why**. They must not track progress.

### Naming

```
docs/prd/<feature-name>.md      ← kebab-case, self-explaining
```

### Required Metadata Block

```markdown
---
title: Brand Health Dashboard
created: 2026-03-11
creator: arhen
workers:
  - fahrizky
  - daffa
status: in-progress          # draft | in-progress | completed | archived
service: web                 # api | web | ai-service | data-service | cross-service
priority: high               # low | medium | high | critical
---
```

### Template

```markdown
# [Feature Name]

## Objective
## Background
## Requirements
### Functional Requirements
### Non-Functional Requirements
## Scope
### In Scope
### Out of Scope
## Technical Approach
## API Contracts
## UI/UX
## Dependencies
## Success Criteria
## Open Questions
```

## D.3 Tracking Files

Tracking files record **implementation progress** for a PRD.

### Naming

```
docs/tracks/<feature-name>.track.md
```

Base name must match the corresponding PRD exactly.

### Required Metadata

```markdown
---
prd: <feature-name>
last_updated: 2026-03-11
updated_by: arhen
---
```

### Template

```markdown
# Tracking: [Feature Name]

## Status Summary

| Aspect | Status |
|---|---|
| Overall | In Progress |
| API | In Progress |
| Frontend | Not Started |
| AI | N/A |
| Data | Completed |

## Milestones

### M1: [Milestone Name] (Target: YYYY-MM-DD)

- [x] Completed task
- [ ] Pending task

## Decisions Log

| Date | Decision | Decided By |
|---|---|---|

## Blockers

## Notes
```

---

# Appendix

## A. Quick Reference: Service Commands

| Service | Directory | Start Dev | Lint/Format | Test | Build |
|---|---|---|---|---|---|
| **API** | `api/` | `php artisan serve --port=9191` | `vendor/bin/pint --dirty` | `php artisan test` | N/A |
| **API Queue** | `api/` | `php artisan queue:work database --timeout=3000 --tries=5 --queue=high,low,default,subscriptions` | — | — | — |
| **Frontend** | `web/` | `bun dev` | `bun lint && bun format` | `bun test` | `bun run build` |
| **AI** | `ai-service/` | `source .venv/bin/activate && fastapi dev` | `ruff check .` | `pytest` | N/A |
| **Data** | `data-service/` | `source venv/bin/activate && uvicorn app.main:app --reload --port 9999` | `ruff check .` | `pytest` | N/A |

## B. Quick Reference: Git Remotes & Branches

```bash
# Check all repo statuses from frnd/ parent:
for dir in api web ai-service data-service; do
  echo "=== $dir ===" && git -C "$dir" status -sb
done
```

## C. Skill Installation (one-shot)

```bash
# Cross-service
npx skills add github/awesome-copilot/git-commit
npx skills add github/awesome-copilot/prd

# Frontend
npx skills add anthropics/skills/frontend-design
npx skills add vercel-labs/agent-skills
npx skills add vercel-labs/next-skills
npx skills add busirocket/tailwindcss-v4
npx skills add radix-ui/design-system

# Verify
npx skills list -g
```

<!-- REFERENCE_END -->
