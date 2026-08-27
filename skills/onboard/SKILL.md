---
name: onboard
description: Full frndOS workspace onboarding — GitHub access, service setup, dependencies, editor config, and MCP configuration. Run this after bootstrap to set up your development environment.
---

# frndOS Workspace Onboarding

This skill guides you through setting up a complete frndOS development workspace. Execute steps in order. Steps marked **STOP** require user input — wait for answers before proceeding.

**References available:**
- `references/service-registry.md` — Full service table (owners, env files, exact start/health commands, port-conflict check).
- `references/external-steps.md` — Protocol for steps that need `sudo` or an interactive terminal the agent can't drive.
- `references/mcp-configs.md` — Per-tool MCP config templates.
- `references/claude-settings.json`, `references/launch.json`, `references/launch-direct.json`, `references/run-all-template.sh` — Workspace config scaffolding.

## Interaction Model — READ THIS FIRST

> **1. Switch to plan mode first.** Before executing anything, switch to your CLI/editor's planning mode:
>   - **Claude Code:** Enter plan mode (`/plan` or Shift+Tab)
>   - **Cursor:** Use chat mode (not agent mode)
>   - **OpenCode:** Switch to Plan agent (Tab)
>   - **Amp:** Amp has no explicit plan mode — explicitly state each plan in chat and wait for approval before acting.
>
> This ensures you present plans and questions to the user and wait for approval before executing.
>
> **2. Steps 0–1 are interactive.** Present ALL questions, wait for answers. Do NOT assume or skip.
>
> **3. After Step 1 — switch to execution mode:**
>   - **Claude Code:** Exit plan mode (normal mode)
>   - **Cursor:** Switch to agent mode
>   - **OpenCode:** Switch to Build agent (Tab)
>   - **Amp:** No mode switch needed — continue in the same session.
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
- **Amp:** Amp has no dedicated ask tool — ask the question as plain text and STOP until the user responds. Do not proceed without an explicit answer.

**NEVER** just print a question as plain text and hope the user responds. **ALWAYS** use the ask tool so the user gets a proper interactive prompt with selectable options. This prevents the agent from continuing without an answer.

## Onboarding State

Throughout onboarding, maintain a `.onboard-state.json` file at the workspace root. **Write/update this file after each step.**

```json
{
  "status": "in_progress|completed",
  "services": ["api", "web", "ai-service", "data-service", "orchestration"],
  "tools": ["claude-code", "cursor"],
  "claude_session_mode": "agent|team",
  "claude_ui": "loki|terminal",
  "jj_available": true,
  "steps": {
    "github_access": "completed|skipped|pending",
    "questionnaire": "completed|pending",
    "prerequisites": "completed|pending",
    "model_access": "completed|skipped|pending",
    "clone_repos": "completed|pending",
    "install_deps": "completed|pending",
    "env_files": "completed|partial|pending",
    "db_setup": "completed|skipped|pending",
    "prefect_setup": "completed|skipped|pending",
    "ch_local": "completed|skipped|pending",
    "run_all_sh": "completed|pending",
    "docs_structure": "completed|pending",
    "editor_tooling": "completed|pending",
    "loki_install": "completed|skipped|pending",
    "community_skills": "completed|pending",
    "mcp_servers": "completed|pending",
    "verify": "completed|pending"
  },
  "env_status": {
    "api": "completed|pending",
    "web": "completed|pending",
    "ai-service": "completed|pending",
    "data-service": "completed|pending",
    "orchestration": "n/a"
  },
  "skipped_reasons": {}
}
```

`claude_ui` is only set when `tools` contains `"claude-code"` — see Step 1.4.5. For all other tool-only workspaces it is absent. `steps.loki_install` is only tracked when `claude_ui == "loki"`.

The workflow engine reads this file. **`/workflow start` will block** if any of these are not resolved:
- `env_files` is not `"completed"` for ALL selected services
- `db_setup` is not `"completed"` (required for API)
- `clone_repos` is not `"completed"`
- `install_deps` is not `"completed"`

The agent must remind the user what's missing and how to fix it.

> **`orchestration` is exempt from the `env_files` gate.** It has no `.env` — its credentials are
> Prefect Secret blocks (Step 6b), so its `env_status` is the literal string `"n/a"`, which
> **satisfies** the gate. Treat `"n/a"` as resolved wherever `"completed"` is required; a strict
> equality check against `"completed"` would block `/workflow start` forever for anyone who selects
> Orchestration, and the file would look correct while doing it.
>
> `steps.ch_local` is likewise **advisory and never blocks** — it records Step 7.4 (the local ClickHouse cluster:
> server, grants, migrations, seed). `steps.prefect_setup` is **advisory and never blocks.** Orchestration work is possible read-only
> without an estate connection — reading flows, editing transforms, running the suite. Only running
> or inspecting real flow runs needs it. Warn, don't block. See Step 6b.3.

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
| 5 | Orchestration | `orchestration/` | Prefect 3, Python 3.12, ClickHouse, AWS S3 | — (no server) |

**If you picked Data Service, pick Orchestration too.** They are two halves of one pipeline:
orchestration writes `frnd_agg_marts.*`, data-service reads it and serves it. "Why is this metric
empty?" is answered in orchestration far more often than in data-service, and adding a metric is a
**two-repo change**. Taking data-service alone leaves half of every data question invisible.

**Also started automatically by `run-all.sh`:**
- **API Queue Worker** — processes background jobs (always runs with API)
- **Mailhog** — captures emails sent by the API for local testing (:1025 SMTP, :8025 UI)

**Orchestration is deliberately NOT in `run-all.sh`.** It has no long-running process. Flows run on
the shared Prefect server (`prefect.frndos.com`); a local Prefect server on `:4200` is opt-in and
only needed for flow development. Nothing to start, nothing to health-check — see Step 12.

### 1.2 Do you have `.env` files ready?

| Service | Env File | Contact |
|---------|---------|---------|
| API | `api/.env` | arhen |
| Frontend | `web/.env.local` | fahrizky, daffa |
| AI Service | `ai-service/.env` | rifki |
| Data Service | `data-service/.env` | kemal, iru |
| Orchestration | Prefect Secret blocks — **not** a `.env` ¹ | fahmi, arhen |

¹ Orchestration is the one service whose runtime credentials do not live in a `.env`. ClickHouse
host/user/password, the data-service callback token and the AWS keys are **Prefect Secret blocks**,
fetched from the server at flow runtime (`orchestration/AGENTS.md` hard rule 10 — never print or
commit a block value). The committed template is `prefect_blocks.staging.example.yaml`; the real
`prefect_blocks.staging.yaml` is gitignored. Setup script: `scripts/setup_staging_blocks.py`, which
is dry-run by default.

> ⚠️ `orchestration/AGENTS.md` and `integrations/clickhouse.py` both reference
> `prefect_blocks.example.yaml` and `scripts/setup_prefect_blocks.py`. **Neither has ever existed
> in that repo.** Use the `staging` names above; do not go looking for the ones the docs name.

### 1.3 Which editor/CLI do you use?

Use the ask tool with these EXACT options (multi-select):

| # | Tool | Type | Description |
|---|------|------|-------------|
| 1 | Claude Code | CLI Agent | Best for complex multi-service tasks, strong tool use |
| 2 | OpenCode | CLI Agent | Lightweight, fast, configurable |
| 3 | Cursor | Editor | Deep AI integration, multi-file editing, agent mode |
| 4 | Amp | CLI Agent | Sourcegraph Amp — reads AGENTS.md + `.agents/skills/` natively, natural-language invocation |
| 5 | Codex | CLI Agent | OpenAI-native code generation |
| 6 | Zed | Editor | Fast, lightweight, multiplayer |
| 7 | Other | — | Type your own |

(Can select multiple — this determines agent, skill, and MCP configuration)

### 1.4 Claude Code session mode (only ask if Claude Code was selected in 1.3)

> "Which session mode do you want for Claude Code?"
> 1. **Agent Session** (recommended) — Single agent handles implementation sequentially. Reliable and predictable.
> 2. **Team Session** (EXPERIMENTAL) — Spawns parallel engineer agents per service + an architect reviewer. Faster for multi-service features but consumes more tokens and hits context window limits sooner. Use with caution.

Record the choice in `.onboard-state.json` as `"claude_session_mode": "agent"` or `"claude_session_mode": "team"`.

If user did NOT select Claude Code in 1.3, skip this question entirely.

### 1.4.5 Claude Code surface — GUI or terminal (only ask if Claude Code was selected in 1.3)

> "How will you drive Claude Code day-to-day?"
> 1. **GUI (loki)** — Native macOS kanban app that manages multiple Claude Code agents in parallel, each with its own git worktree, with phase-aware columns, diff viewer, and docs pane. Requires macOS. Install: See github.com/arhen/loki for installation instructions.
> 2. **Terminal** — Drive Claude Code from your shell. Use `/jj-workflow` for parallel features when you want a second session in another directory. Works on macOS/Linux/Windows.

Record the choice in `.onboard-state.json` as `"claude_ui": "loki"` or `"claude_ui": "terminal"`.

**Implications to communicate to the user before moving on:**

- **GUI:** `/jj-workflow` becomes a no-op in this workspace (loki's worktrees replace JJ's parallel-workspace story). The other agent tools (Cursor/OpenCode/Amp) are unaffected if the user also selected them — they keep working in terminal with `/jj-workflow` available, but loki only sees the Claude Code side.
- **Terminal:** Nothing changes from today's flow. JJ setup continues in Step 2.5 if applicable.

**Platform gate:** If the user picks GUI but is on Linux/Windows, tell them "loki is macOS-only today. Falling back to terminal mode." and set `claude_ui: "terminal"` + `skipped_reasons.loki_install: "non-macOS platform"`. Detect OS via `uname -s` — `Darwin` means macOS, anything else falls back.

**Multi-tool caveat:** If the user selected Claude Code **and** one or more terminal tools (Amp, OpenCode, Cursor), GUI mode still applies to Claude Code only. Record this explicitly in state: the GUI choice covers the Claude Code surface, and the terminal tools continue to use `/jj-workflow` if they want parallel features. They share the same `.workflow-state.json` and Lark tasklist, so team visibility is consistent either way.

If user did NOT select Claude Code in 1.3, skip this question entirely.

### 1.5 Which AI provider subscriptions?

- Anthropic: Claude Opus 4.6 (planning), Claude Sonnet 4.6 (coding)
- OpenAI: GPT 5.3-codex (coding), GPT 5.4 (exploratory)

### 1.6 Optional integrations

- **Lark MCP** — Read PRDs directly from Lark doc URLs (skip copy-paste)
- **Figma MCP** — Read designs from Figma, extract component specs

Neither is required. Workflow works without them.

---

> **Switch to execution mode now.** The user has answered all questions.
> - **Claude Code:** Exit plan mode (normal mode)
> - **Cursor:** Switch to agent mode
> - **OpenCode:** Switch to Build agent (Tab)
> - **Amp:** No mode switch needed — continue.
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
| ClickHouse client ¹ | `command -v clickhouse` | Missing → `brew install --cask clickhouse`. Installed → keep |

¹ **Orchestration and Data Service only** — skip if neither was selected. Note it is a Homebrew
**cask**, not a formula: `brew install clickhouse` fails (`No available formula`), and
`clickhouse-cpp` is a C++ client library, not the CLI. The official single-binary installer from
`clickhouse.com` is an equally valid route and is what produces the `clickhouse` binary people
usually have in `~/.local/bin`. Client only — no local server is needed or wanted; the transform
points at a real cluster.

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

Save the environment method in `.onboard-state.json` and proceed to Step 2.5. All subsequent steps (clone, deps, .env, DB) work the same regardless of Nix or direct install.

## Step 2.5: JJ (Jujutsu) Setup — Terminal-based harnesses only

**Skip this step entirely if none of the following apply:**
- Amp was selected in Step 1.3
- Claude Code was selected in Step 1.3 **AND** `claude_ui` from Step 1.4.5 is `"terminal"`

Rationale: JJ workspaces are the terminal-mode parallel-feature story. When Claude Code runs under loki (`claude_ui: "loki"`), loki's git worktrees replace JJ, and the `/jj-workflow` skill is inert in this workspace (it detects `.loki/marker.json` and exits). If the user additionally picked Amp (which has no GUI equivalent), JJ is still installed — Amp runs alongside loki and uses JJ for its own parallel sessions. Cursor and OpenCode alone don't need JJ (IDE-integrated / per-session), so they don't trigger this step.

JJ enables parallel feature development via isolated workspaces — useful when you run one agent session per directory. It runs in colocated mode alongside git — all git commands remain unchanged.

1. **Check if JJ is available:**
   ```bash
   command -v jj &>/dev/null && echo "✓ jj available: $(jj --version)" || echo "✗ jj not found"
   ```

2. **If JJ is found** (e.g., from Nix flake or pre-installed):
   - Record `jj_available: true` in `.onboard-state.json`
   - Tell user: "JJ detected. After onboarding, you can use `/jj-workflow init` to enable colocated mode in service repos, then `/jj-workflow new <slug>` to create parallel workspaces for simultaneous feature development."
   - **Do NOT run `jj git init --colocate` yet** — repos haven't been cloned. The user will run `/jj-workflow init` after clone.

3. **If JJ is NOT found:**
   - Use the ask tool:
     > "JJ (Jujutsu) enables parallel feature development — work on multiple features in separate directories simultaneously. It's optional and only useful with terminal-based harnesses (Claude Code, Amp)."
     > - **Install JJ** (`brew install jj`) — recommended if you plan to work on multiple features in parallel
     > - **Skip** — I'll work on one feature at a time
   - If user chooses install:
     ```bash
     brew install jj
     ```
     Verify: `command -v jj && echo "✓ jj installed"`. Record `jj_available: true`.
   - If user chooses skip: record `jj_available: false`. They can install later.

4. **After clone (Step 4)**, if `jj_available` is `true`:
   - Automatically run the equivalent of `/jj-workflow init`:
     ```bash
     for service in api web ai-service data-service orchestration; do
       if [ -d "$service/.git" ] && [ ! -d "$service/.jj" ]; then
         cd "$service" && jj git init --colocate && cd ..
       fi
     done
     ```
   - Report which repos were initialized

## Step 3: Verify Model Access

Based on CLI choice and subscriptions from Step 1:

**Claude Code:**
```bash
echo "OK" | claude -p --model claude-opus-4-7 2>&1 | head -1
echo "OK" | claude -p --model claude-sonnet-4-6 2>&1 | head -1
```

**OpenCode:**
```bash
opencode run -m anthropic/claude-opus-4-7 "respond with just OK" 2>&1 | head -5
```

**Amp:**
```bash
command -v amp && amp --version 2>&1 | head -1
```
Amp manages model access internally via your Amp account — no per-model CLI verification needed. If `amp` is not found, ask the user to install it from [ampcode.com](https://ampcode.com).

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

# Orchestration — the transform layer (raw -> staging -> frnd_agg_marts)
# Staging-first: check out `staging`, which is the working base. `main` is the
# repo default AND the production branch — reached by a separate promotion PR.
[ -d "orchestration" ] || (git clone https://github.com/alva-intelligence/frnd-orchestration.git orchestration && cd orchestration && git checkout staging)
```

> **Why orchestration is worth cloning even if you never edit it.** The marts every dashboard reads
> are produced here, not in `data-service` — data-service *serves* them. So "why is this metric
> empty?" is usually answered in this repo, and adding a metric is a **two-repo change**: the
> projection that computes the column lives here, the endpoint that exposes it lives in
> data-service. Without this clone, half of every data question is invisible.
>
> ⚠️ **orchestration is staging-first; `main` is production.** Verified on the estate 2026-08-27: **production** deployments pull `main` (pool `local-pool`, queue `ads`); **staging** deployments pull `staging` (pool `staging-pool`, queue `ads-staging`, tag `branch:staging`), and both pools report `READY`, meaning a live worker is polling each. So a merge to `main` reaches **production**.
>
> **Feature work branches from `staging` and PRs into `staging`.** Reaching production is a **separate promotion PR, `staging` → `main`**, opened deliberately by a human — never as part of a feature. `main` is a strict ancestor of `staging` (43 behind, 0 ahead as of 2026-08-27), so the promotion is a clean merge. Open the PR and stop either way: never merge it yourself, never push to `staging` or `main`.

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

# Orchestration — standard venv as .venv on Python 3.12 (the deployed worker's runtime).
# `python3` is NOT reliably 3.12: brew's python@3.12 is keg-only and does not relink
# `python3`, so a bare `python3 -m venv` silently builds on whatever is first on PATH.
PY312="$(command -v python3.12 || command -v python3)"
cd orchestration && "$PY312" -m venv .venv && cd ..
```

Verify the interpreter before installing anything into it:

```bash
orchestration/.venv/bin/python --version
```

> ⚠️ **If that is not 3.12, say so and ask before continuing.** The deployed Prefect worker runs
> 3.12 and `orchestration/pyproject.toml` pins `target-version = "py312"` with a comment saying it
> matches *"the runtime this repo actually deploys on — not the interpreter that happens to be on a
> contributor's PATH."* A newer interpreter installs and runs fine today — this was measured on
> 3.14.6: 206 tests pass — so the divergence is **silent**, which is what makes it worth catching
> here rather than in a production-only failure later. If `python3.12` is absent, Step 2 installs it.
>
> ⚠️ `orchestration/README.md` says `python -m venv venv` (no dot). Use `.venv` so the path matches
> ai-service and data-service and the editor tooling in Step 9 finds it.

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

# Orchestration (venv already created in 5.1) — needs requirements-dev.txt for pytest
cd orchestration && source .venv/bin/activate && pip install -r requirements.txt -r requirements-dev.txt && deactivate; cd ..
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

## Step 6b: Prefect profiles & Secret blocks — **STOP** (Orchestration only)

Skip this entire step if the user did not select Orchestration.

Orchestration is the one service with **no `.env`**. Its runtime credentials are Prefect Secret
blocks fetched from the server at flow time, and the server connection itself comes from a profile
file that lives **outside the workspace**. Two artifacts, two different places:

| Artifact | Path | Contains | Source |
|---|---|---|---|
| Prefect profiles | `~/.prefect/profiles.toml` (**outside the repo**) | API URL + `PREFECT_API_AUTH_STRING` per estate | Lark `secrets` folder → `secrets/all env/profiles.toml` |
| Secret blocks | on the Prefect server, not on disk | ClickHouse host/port/user/pass, callback token, AWS keys | created in Step 7.5.3, values from the same Lark folder |

#### 6b.1 Profiles — ask, then wait

The committed placeholder template is `orchestration/config_handover/profiles.toml.example`. The
real file is **not** in the repo and must never be committed.

Use the ask tool:

> "Orchestration needs `~/.prefect/profiles.toml`. It carries the Prefect server URL and the basic-auth
> string for the shared estate. Do you have it?"
> - Yes — I have the file (or the values)
> - No — I need it from fahmi

If **"No"**: tell the user to ask **fahmi** for `secrets/all env/profiles.toml` from the team's Lark
`secrets` folder. Mark `steps.prefect_setup` as `"pending"` and continue onboarding — this does not
block the rest.

If **"Yes"**: the user copies it into place themselves. **The agent must not write this file** — it
contains a plaintext production credential and it lives outside the workspace.

```bash
# The USER runs this, not the agent:
cp "<downloaded>/profiles.toml" ~/.prefect/profiles.toml
chmod 600 ~/.prefect/profiles.toml
```

#### 6b.2 Verify — read-only, never mutate

```bash
cd orchestration
.venv/bin/prefect profile ls                                    # expect: frndos_prefect, local
PREFECT_PROFILE=frndos_prefect .venv/bin/prefect deployment ls
```

> `prefect` is installed **into `orchestration/.venv`** by `requirements.txt` (Step 5.2) — there is
> no global `prefect` on a fresh machine. Every Prefect command in this skill is written as
> `.venv/bin/prefect` for that reason. A bare `prefect` will fail with command-not-found unless the
> user happens to have activated the venv.

The second command should list `webhook-sync` and `webhook-delete`. Any output means the profile
works.

> ⚠️ **Never run `prefect profile use` or `prefect config set` to do this.** Both rewrite
> `~/.prefect/profiles.toml` **globally** and silently retarget every later Prefect command on the
> machine — including the user's own terminal, and including commands that hit production. Pin the
> profile per command with the `PREFECT_PROFILE=` prefix, every time. Both are denied in
> `.claude/settings.json`; if one prompts, that is the guard working — ask, do not route around it.

#### 6b.3 Record

Set `steps.prefect_setup` in `.onboard-state.json` to `"completed"`, `"pending"`, or `"skipped"`.

**This does NOT block `/workflow start`** — unlike the API's database dump. Orchestration work is
possible read-only without a working estate connection: reading flows, editing transforms, running
the test suite. Only actually running or inspecting flows needs it. Warn, don't block.

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

### 7.4 Local ClickHouse — **Data Service and/or Orchestration**

Skip if the user selected neither. This is the ClickHouse equivalent of 7.1's PostgreSQL setup, and
it is **shared**: orchestration writes `frnd_agg_marts.*` into this cluster and data-service reads
them out. Set it up once, for both.

> **Why this step exists.** `data-service` documents a local ClickHouse in its own `README.md` §4 and
> `orchestration`'s raw seeder refuses to run anywhere else — but onboarding has never set one up, so
> a data-service developer got a `.env` pointing at a shared remote cluster and no local database at
> all. api gets `initdb`, a dump, `artisan migrate` and a blocking gate; ClickHouse got nothing.

> ⛔ **The agent does not run 7.4.3, 7.4.4 or 7.4.5 — the user does.** `Bash(clickhouse client:*)` and
> `Bash(clickhouse-client:*)` are denied in `.claude/settings.json`, because a `clickhouse client
> --query "…"` invocation carries arbitrary SQL as its payload: the pattern cannot tell a `SELECT`
> from a `DROP`, and these sub-steps create users, grant privileges, apply 93 DDL files and insert
> seed rows. Same shape as 7.5.3 and 7.5.5 for Prefect.
>
> So follow `references/external-steps.md` for each: **tell the user exactly what to run, ask, wait,
> verify what you can see, do not skip.** The agent may read `.sql` files, count them, and check that
> paths exist — it may not execute anything against the cluster. If a `clickhouse client` call
> prompts, that is the guard working: ask, do not route around it.

#### 7.4.1 ClickHouse — client, and optionally a local server

The `clickhouse` binary is **both**: `clickhouse client` connects to a cluster, `clickhouse server`
runs one. There is no separate client package — that is why `brew install clickhouse` finds no
formula and the cask ships one binary. Verify:

```bash
command -v clickhouse && clickhouse client --version || echo "✗ clickhouse not found"
```

If missing, see Step 2. Then pick a mode — **the choice decides whether 7.5 is available at all:**

| Mode | ClickHouse | What works | What does not |
|---|---|---|---|
| **Remote** (default) | a Cloud cluster — staging, or the developer's own | Running flows against real data | Seeding raw locally. `local-seed-raw.py` **refuses any host but `localhost`** |
| **Local server** | `clickhouse server` on `:8123` | Everything, including Step 7.5's raw seed and a full raw → staging → mart chain offline | Nothing real — it starts empty |

For the local-server mode:

```bash
clickhouse server    # binds :8123 (HTTP) and :9000 (native) — keep this terminal open
```

Point the `clickhouse-*` Secret blocks from 7.4.4 at `localhost` when you choose it.

> **This is the same local ClickHouse `data-service` documents in its own `README.md` §4**, with the
> same install line. The two services share one local cluster: orchestration writes
> `frnd_agg_marts.*` into it, data-service reads them out. Set it up once.


#### 7.4.2 Start the local server

Only in local-server mode. The binary serves HTTP on `:8123` and native on `:9000`.

```bash
clickhouse server    # keep this terminal open
```

Verify from another terminal — **the user runs this**, same reason as 7.4.3:

```bash
clickhouse client --query "SELECT version()"
```

The agent can confirm the server is up without the client, which is not denied:

```bash
curl -s http://localhost:8123/ping    # expects "Ok."
```

Windows uses Docker and Linux uses the distro packages — both are in
`data-service/README.md` §4. Do not re-document them here; send the user there.

#### 7.4.3 Users, grants and the migration tracker — **user runs these**

Two one-time pieces, in this order.

**a. Service user and privileges** — `data-service` ships a single idempotent bootstrap:

```bash
clickhouse client --queries-file data-service/database/bootstrap/setup.sql
```

It creates the `frndos_data_service` user, revokes anything over-granted, and grants exactly what
the service's code paths need. Re-runnable on any environment.

**b. The migration tracker** — ClickHouse has no built-in migration table, so the repo uses a
convention: one row per applied file in `frnd_meta.schema_migrations`.

```bash
clickhouse client --query "CREATE DATABASE IF NOT EXISTS frnd_meta"
clickhouse client --query "
CREATE TABLE IF NOT EXISTS frnd_meta.schema_migrations (
    migration_id String,
    applied_at   DateTime DEFAULT now(),
    applied_by   String   DEFAULT currentUser(),
    checksum     String
) ENGINE = MergeTree ORDER BY (migration_id)"
```

> ⚠️ **Two deviations from `data-service/database/README.md`, both deliberate.**
> 1. That file's DDL uses `ENGINE = SharedMergeTree(...)`, which is **ClickHouse Cloud only**. On an
>    OSS server it fails with `Code: 56 … Unknown table engine SharedMergeTree` — verified against
>    26.8.1.71. Use `MergeTree` locally; leave the Cloud DDL alone for Cloud.
> 2. That file's snippet creates the table without creating `frnd_meta` first, so it fails on a fresh
>    server. The `CREATE DATABASE` above is the missing line.

#### 7.4.4 Apply the migrations — **user runs these**

**93 files**, numbered **globally across all databases** so the run order is unambiguous —
`frnd_agg_marts` 55, `frnd_os_master` 25, `temp_telkomsel_rafi` 11, `frnd_ai_database` 2. Engines are
`ReplacingMergeTree` (65), `MergeTree` (14) and `SummingMergeTree` (1); none is Cloud-only, so they
all run on the local server.

> **There is no migration runner.** `data-service/database/README.md` §"Simple Python Runner" says
> one *could* live at `database/migrate.py` — it does not exist, and `scripts/run_migration_017.py`
> is a one-off that proves the absence. Apply them in numeric order and record each one.

##### The same DDL lives in two repos — read this before you apply anything

`frnd_agg_marts`'s DDL is **55 `.sql` files that exist twice**, byte-for-byte:

| Copy | Runner | Tracked in |
|---|---|---|
| `data-service/database/migrations/frnd_agg_marts/` | manual `.sql` execution (the loop below) | `frnd_meta.schema_migrations` — a documented convention **nothing implements** |
| `orchestration/database/migrations/frnd_agg_marts/` | 20 Alembic revisions that **wrap** the files — `run_sql_file('frnd_agg_marts/v2/001_….sql')` | `alembic_version`, applied inline by `tasks/migrate_marts.py` on every sync |

Verified 2026-08-27: **55 files on each side, all 55 identical, no drift in either direction.**

Three things follow, and they are the difference between a working local cluster and a confusing one:

1. **These are not two competing DDL definitions.** Alembic here is an *ordering and tracking
   wrapper*, not a DDL generator — each revision is four lines that run one `.sql` file and record
   that it ran. So `data-service/database/README.md`'s "do not use Alembic — it assumes transactional
   rollbacks" and orchestration's use of Alembic do **not** conflict: nothing rolls back
   (`downgrade = irreversible(...)`), and the SQL is the same SQL.
2. **Alembic covers 18 of the 36 tables.** Every table orchestration's revisions create is also
   created by data-service's tree; data-service has 18 more that Alembic never wraps. Applying
   data-service's set gives you the superset — do that first.
3. **Order does not matter, but drift would.** Every file is `CREATE TABLE IF NOT EXISTS`, so if you
   apply data-service's set and then run an orchestration flow, `migrate_marts` re-runs the same
   statements as no-ops and stamps `alembic_version`. That is safe **only while the two trees stay
   identical.** Nothing enforces that today. If a mart column ever appears on one side and not the
   other, the cluster silently keeps whichever ran first while both trackers claim to be at head.

> ⚠️ Mart DDL ownership **moved to orchestration on 2026-08-26**, but only on
> `frnd-orchestration:staging` and `frnd-clickhouse-api:development` — **neither repo's `main`**. So
> which copy is authoritative depends on the branch you checked out. Adding a mart column is an
> orchestration change on those branches and a data-service change on `main`. Check before you
> write one.

```bash
cd data-service
find database/migrations -name '*.sql' | sort -t/ -k4 | while read -r f; do
  id="${f#database/migrations/}"
  applied=$(clickhouse client --query \
    "SELECT count() FROM frnd_meta.schema_migrations WHERE migration_id = '$id'")
  if [ "$applied" = "0" ]; then
    echo "applying $id"
    clickhouse client --queries-file "$f" || { echo "FAILED $id"; break; }
    clickhouse client --query "INSERT INTO frnd_meta.schema_migrations (migration_id, checksum) \
      VALUES ('$id', '$(shasum -a 256 "$f" | cut -d' ' -f1)')"
  fi
done
cd ..
```

Stop on the first failure and show the user the file — do not skip past it. Ask them how many applied.

What the **agent** can do here without touching the cluster: confirm the count is 93
(`find data-service/database/migrations -name '*.sql' | wc -l`), confirm the numeric ordering is
unambiguous, and read any file the user's failure names.

#### 7.4.5 Seed — **user runs these**

Two seeding strategies, for two different jobs. Pick by what the user selected; run both if both.

| | **data-service** — manufactured marts | **orchestration** — derived raw |
|---|---|---|
| What it fills | `frnd_agg_marts.*`, `frnd_os_master`, `frnd_ai_database` | `raw_<alias>_<brand>` — the Fivetran landing zone |
| Where shape comes from | hand-written per-mart generators | `orchestration/config_handover/*.yaml`, the Fivetran allow-list, so the fixture cannot drift |
| Gives you | dashboards with data, without running a pipeline | a source the transforms can actually read |
| Step | below | **7.6** |

**data-service — generated marts.** Plain scripts, no runner; run from the repo root:

```bash
cd data-service
python database/seeders/frnd_agg_marts/v2/000_generate_fake_data.py    # medium-volume base
python database/seeders/frnd_agg_marts/demo/seed_demo.py               # demo workspace + 3 brands
cd ..
```

`000_generate_fake_data.py` inserts as the `default` superuser and **does not truncate** — re-running
adds duplicates, which `ReplacingMergeTree` dedups by `ORDER BY`. `seed_demo.py` copies rows from the
realistic brands (`simpati` → `frndbank`, `frndglow` → `frndskincare` / `frndairline`), rewrites them
with the demo ULIDs, shifts every date into a rolling 90-day window ending today, and applies a
per-brand volume multiplier; it auto-generates its source data if absent. The 30 `.sql` seeders under
`database/seeders/frnd_agg_marts/` are the older v1 set — the Python ones supersede them.

> ⚠️ **The demo ULIDs are a cross-repo contract.** `seed_demo.py` reads them from
> `data-service/demo-ulids.json`; the api's `DemoWorkspaceSeeder` reads the same values from
> `api/demo-ulids.json`. **Two copies, no shared source** — the PRD specified
> `.agentic-workflows/constants/demo-ulids.json` and it was never created. If Postgres and ClickHouse
> demo data disagree, this is why. Do not edit one without the other.

Record `steps.ch_local` in `.onboard-state.json`.


### 7.5 Local Prefect — **Orchestration only**

Skip if the user did not select Orchestration.

#### 7.5.1 Confirm the `local` Prefect profile

`~/.prefect/profiles.toml` from Step 6b already carries a `local` profile alongside
`frndos_prefect`. Confirm it, don't create it:

```bash
cd orchestration && .venv/bin/prefect profile ls    # expect `local` in the list
```

> If `local` is missing, **the user creates it**, not the agent. The two commands that would do it
> — `prefect profile use` and `prefect config set` — are denied in `.claude/settings.json` because
> they rewrite `~/.prefect/profiles.toml` globally and silently retarget every later Prefect
> command on the machine, including ones that reach production. Hand the user these two lines and
> wait:
>
> ```bash
> prefect profile create local
> prefect config set PREFECT_API_URL="http://127.0.0.1:4200/api"
> ```

**Every command below pins the profile with a `PREFECT_PROFILE=` prefix.** Never `prefect profile
use`. This is not style — the prefix is scoped to one command; `profile use` is not.

#### 7.5.2 Terminal 1 — the local server (leave running)

```bash
cd orchestration && PREFECT_PROFILE=local .venv/bin/prefect server start
```

Serves `http://127.0.0.1:4200`. **This is the one port orchestration can contend for** — add `4200`
to the port-conflict check in `references/service-registry.md` when this step is in play.

#### 7.5.3 Terminal 2 — Secret blocks

The flows read **every** credential from Prefect `Secret` blocks, not a `.env`. Create them on the
**local** server via the UI at `http://127.0.0.1:4200` → Blocks → Secret. Values come from the
Lark `secrets` folder → `all env` (a zip holding the filled-in block YAML). Ask **fahmi**.

> **The agent cannot do this step.** `prefect block create` and `prefect block delete` are denied,
> and no script creates local blocks — `scripts/setup_prefect_blocks.py` and
> `prefect_blocks.example.yaml` are referenced by that repo's own docs and `integrations/clickhouse.py`
> but **have never existed**. The only block script in the repo is `scripts/setup_staging_blocks.py`,
> which creates `-staging` siblings on a remote estate and is not the local path. UI or nothing.

Minimum set to run an organic transform end to end:

| Block | Value |
|---|---|
| `clickhouse-host`, `clickhouse-port`, `clickhouse-user`, `clickhouse-pass` | The ClickHouse the transform reads raw from and writes marts to |
| `clickhouse-host-staging` | For pure local, set equal to `clickhouse-host` |
| `environment` | `local` |
| `openai-key` | Sentiment classification (organic paths only) |

`data-service-callback-token`, the four `aws-*` blocks, `github-pat` and `rapid-api-key` are only
needed for the callback, the creative-assets S3 mirror, cloud deployments and KOL enrichment
respectively. `meta-access-token` and `tiktok-ads-token` appear in Lark but **no flow loads them** —
skip. Never print, log or commit a block value.

#### 7.5.4 The `staging_date_cutoff` Variable

One Prefect Variable gates how far back data is kept, project-wide — rows older than it are dropped
from staging, marts and creative-assets. Set it to the **same value production uses**:

```bash
PREFECT_PROFILE=local .venv/bin/prefect variable set staging_date_cutoff "2025-01-01"
```

Source of truth is the live Variable on `prefect.frndos.com`; read it any time with
`PREFECT_PROFILE=frndos_prefect .venv/bin/prefect variable get staging_date_cutoff` and keep local
in sync.
The hardcoded constant in `tasks/transform_helpers.py` is a last-resort default only.

#### 7.5.5 Work pool, deployments, worker — **user runs these**

```bash
# Terminal 2
cd orchestration
PREFECT_PROFILE=local .venv/bin/prefect work-pool create local-pool --type process
PREFECT_PROFILE=local .venv/bin/python scripts/register_paid_deployments.py --env production
PREFECT_PROFILE=local .venv/bin/prefect worker start --pool local-pool   # leave running
```

> ⚠️ **The agent must not run the middle line.** `Bash(*register_paid_deployments*)` is denied on
> purpose: the script takes `--env` and the active profile decides *which server* it writes to, so
> the same command that registers six local deployments will register them against
> `prefect.frndos.com` if the profile is wrong. `--env production` is correct here — it produces the
> unsuffixed deployment names the local worker expects; it does **not** mean production. Have the
> user confirm the `PREFECT_PROFILE=local` prefix is present before they run it.

#### 7.5.6 Smoke test

```bash
PREFECT_PROFILE=local .venv/bin/prefect deployment run testing-worker/smoke-testing
```

Completing means the worker can reach ClickHouse with the blocks from 7.5.3. Watch it at
`http://127.0.0.1:4200`. Record `steps.ch_local` in `.onboard-state.json`.

### 7.6 Seed the local raw layer — **Orchestration only, optional**

Requires the **local server** mode from 7.4.2 — this seeder refuses any host but `localhost`.

A local ClickHouse has *placeholder* raw tables: every `raw_ig_*.media_insights` has five columns
(`id, name, value, _fivetran_synced, _fivetran_deleted`) rather than the real per-type metric
tables. So the transforms read nothing, and **every metric downstream renders as an em dash**. That
looks like a pipeline bug and is not one — it is an absent source.

The seeder builds that source: real table shapes derived from `orchestration/config_handover/*.yaml`
(the Fivetran allow-list, so the fixture cannot drift from what the transformers expect), plausible
rows, one sandbox brand, entirely on localhost.

```bash
# The script is mid-relocation — check both paths.
SEED=""
[ -f orchestration/scripts/seed_local_raw.py ] && SEED="orchestration/scripts/seed_local_raw.py"
[ -z "$SEED" ] && [ -f scripts/local-seed-raw.py ] && SEED="scripts/local-seed-raw.py"
[ -n "$SEED" ] && echo "seeder: $SEED" || echo "○ no local raw seeder found — ask fahmi"
```

If neither path exists, skip and tell the user that local flow runs will produce empty marts until
a raw layer exists. This is expected, not a failure.

## Step 7b: Create run-all.sh

If `run-all.sh` doesn't exist in the workspace root, create it from the template at [references/run-all-template.sh](references/run-all-template.sh).

Make it executable: `chmod +x run-all.sh`

## Step 8: Set Up Documentation Structure

```bash
mkdir -p docs/prd
for service in api web ai-service data-service orchestration; do
  if [ -d "$service" ]; then
    mkdir -p "$service/docs/prd" "$service/docs/tracks"
  fi
done
```

## Step 9: Configure Editor Tooling

The bootstrap installed frndOS agents to `.agentic-workflows/agents/<tool>/` and skills to `.agents/skills/`. Each tool symlinks to its platform-specific agents.

**Additional per-tool setup:**

**Claude Code:** Verify `CLAUDE.md` symlink exists → `AGENTS.md`. Agents symlinked from `.agentic-workflows/agents/claude-code/`:
```bash
mkdir -p .claude
ln -sf ../.agentic-workflows/agents/claude-code .claude/agents
```

Configure project settings — copy the base template, then modify based on session mode:

```bash
cp .agents/skills/onboard/references/claude-settings.json .claude/settings.json
```

> **Auto-mode coverage:** the base template ships with `permissions.allow` covering every command the workflow needs (git, gh, jj, lark-cli, jq, scoped Edit/Write to `docs/` + state files), a `permissions.deny` blocklist for destructive commands, and `autoMode.environment` hints that mark Lark as trusted infrastructure and JJ secondary-workspace symlinks as in-scope. This means the workflow runs hands-off under Claude Code's auto mode (`https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode`) without sandbox prompts breaking sub-agents. Users who want to TIGHTEN beyond the defaults should edit `.claude/settings.json` after install; users who want personal additions should put them in `.claude/settings.local.json` (gitignored).

**If user chose "Team Session" (`claude_session_mode: "team"`) in Step 1.4:**
- Read `.claude/settings.json`
- Set `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` to `"1"`
- Write the updated file back
- Warn user: "Team Session mode is experimental. It consumes more tokens and may hit context window limits faster."

**If user chose "Agent Session" (`claude_session_mode: "agent"`) or skipped the question:**
- No modification needed — the base template already has an empty `env`.

**Switching modes later:** The user can switch between Agent Session and Team Session at any time by running `/workflow mode`. See the workflow skill for details.

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

**Amp:** If user selected Amp, check `.amp/agents/` symlink exists pointing to Amp-specific agents. If not:
```bash
mkdir -p .amp
ln -sf ../.agentic-workflows/agents/amp .amp/agents
```
> **Note:** Amp reads skills from `.agents/skills/` natively — no `.amp/skills/` symlink is needed. AGENTS.md at the workspace root is also read automatically.

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

## Step 9.5: Install loki (only if `claude_ui == "loki"`)

**Skip this step unless Claude Code was selected AND the user chose GUI in Step 1.4.5.**

loki is the native macOS GUI shell for the agentic workflow when Claude Code is the chosen tool. It runs the Claude Code side of the workspace — kanban (features grouped by workflow phase via `workflow/phases.json.kanban_lanes`), per-card git worktree, chat/diff/terminal/LSP views, and a Docs pane that reads `docs/prd/*.md` with backlinks and a "Sync to Lark wiki" button that calls `/lark-sync push-prd`.

### 9.5.1 Re-verify macOS

```bash
[[ "$(uname -s)" == "Darwin" ]] && echo "✓ macOS" || echo "✗ Not macOS — loki is macOS-only"
```

If not macOS, something went wrong upstream (Step 1.4.5 should have caught this). Revert `claude_ui` to `"terminal"`, set `skipped_reasons.loki_install: "non-macOS platform"`, and move on to Step 10.

### 9.5.2 Install loki — **STOP, ask user**

Installation lives outside this workspace (loki ships through its own channel — brew tap, dmg, or source build from `github.com/arhen/loki`).

Use the ask tool:

> "Install loki now?"
> - **Install loki** — I'll walk you through installing from github.com/arhen/loki
> - **I'll install it myself** — I already have loki or will install it from github.com/arhen/loki later
> - **Skip, fall back to terminal** — Change my mind, use terminal mode instead

**If "Install loki":**

Tell the user: "loki is not on Homebrew yet. Please install it from github.com/arhen/loki. Run the installer in a separate terminal, then come back."

Do NOT run the install for the user — it may require sudo or take a long time. Let the user drive it.

**STOP AND WAIT.** Use the ask tool:
> "Is loki installed?"
> - Yes, `loki --version` works
> - Not yet, I need more time
> - Install failed — I'll fall back to terminal mode

If "Not yet": repeat the wait.
If "Install failed": set `claude_ui: "terminal"`, `skipped_reasons.loki_install: "install failed — falling back to terminal"`, and move on to Step 10. Tell the user `/jj-workflow` is now active for their workspace.
If "Yes": continue to 9.5.3.

**If "I'll install it myself":** set `steps.loki_install: "pending"` and continue to 9.5.3 — the marker check will still catch whether loki actually ran.

**If "Skip, fall back to terminal":** set `claude_ui: "terminal"`, `skipped_reasons.loki_install: "user skipped"`, and move on to Step 10. If JJ was NOT already installed in Step 2.5 (because GUI was chosen at the time), tell the user: "Since you're back on terminal, consider running `/jj-workflow init` later if you want parallel-workspace support. `brew install jj` if it's not already installed."

### 9.5.3 Launch loki and verify marker

Tell the user:

> "Open loki. On first launch:
> 1. Point it at this workspace directory: `$(pwd)`
> 2. When prompted, accept the bootstrap detection — loki will see `.agentic-workflows/` and recognize this is an agentic-workflows workspace
> 3. loki will write `.loki/marker.json` to claim the workspace
>
> Let me know when loki has launched and opened this workspace."

**STOP AND WAIT.** Use the ask tool:
> "Has loki opened this workspace?"
> - Yes, it's running and shows my workspace
> - Not yet
> - I'm having trouble — let's skip and fall back to terminal

If "Yes": verify the marker file exists:
```bash
if [ -f .loki/marker.json ]; then
  version=$(jq -r '.version // "unknown"' .loki/marker.json 2>/dev/null || echo "unknown")
  echo "✓ loki marker found (version $version)"
else
  echo "✗ .loki/marker.json not found — loki may not have claimed this workspace yet"
fi
```

If marker exists: set `steps.loki_install: "completed"`. Tell the user: "loki is now managing this workspace. `/jj-workflow` is inert here — use the kanban GUI to add/remove feature workspaces."

If marker missing after "Yes": ask user to check loki's logs or to retry pointing at this directory. If still missing after one retry, fall back:
- Set `claude_ui: "terminal"`, `steps.loki_install: "failed"`, `skipped_reasons.loki_install: "marker not written — loki may not have detected workspace"`.
- Tell user: "Falling back to terminal mode. You can retry loki later by launching it and pointing at this directory."

If "I'm having trouble": fall back to terminal as above.

### 9.5.4 Tell the user what changes in the workspace

When `claude_ui == "loki"` and the marker is in place:
- `/jj-workflow new/list/cleanup/init` all print a redirect message and exit (no action). Parallel features come from adding cards in loki.
- `/workflow start <slug>` still works from the terminal — the agent and the GUI share `.workflow-state.json` as the source of truth. Whichever side creates a feature first, the other sees it on next poll / session.
- Lark sync behavior is unchanged — the orchestra hooks still run on `/workflow start` and `/workflow next`, and loki's "Sync to Lark wiki" button in the Docs pane calls `/lark-sync push-prd` for the selected PRD.
- Uninstalling loki later: `rm -rf .loki/` in the workspace, then `/jj-workflow init` becomes usable again (re-run onboard Step 2.5 if JJ was never installed).

## Step 10: Install Community Skills

Skills are installed via [skills.sh](https://skills.sh/) using `npx skills add`.

**IMPORTANT:**
- Always use `--yes` flag — the skills CLI requires an interactive TTY for prompts. Without `--yes`, the install will hang in agent sessions.
- Always use `-a` flag to target only the user's selected tools from Step 1.3. This prevents creating unnecessary editor folders.

**Build the `-a` flags** from the user's tool selection in Step 1.3:
- If Claude Code selected: `-a claude-code`
- If Cursor selected: `-a cursor`
- If OpenCode selected: `-a opencode`
- If Amp selected: skills.sh does not yet ship an `-a amp` target. Since Amp reads `.agents/skills/` natively, use another `-a` target that installs into `.agents/skills/` (typically `-a claude-code`) so the files land where Amp can find them. If the user only selected Amp, pass `-a claude-code` — Amp will still load the skills.

Example for a user who selected Claude Code + Cursor: `--yes -a claude-code -a cursor`

**Always install (cross-service):**
```bash
npx skills add https://github.com/github/awesome-copilot --skill git-commit --yes -a <tools>
npx skills add https://github.com/github/awesome-copilot --skill prd --yes -a <tools>
```

**If user works on Frontend (`web/`):**
```bash
npx skills add anthropics/skills@frontend-design --yes -a <tools>
npx skills add vercel-labs/agent-skills@vercel-react-best-practices --yes -a <tools>
npx skills add vercel-labs/next-skills@next-best-practices --yes -a <tools>
npx skills add busirocket/agents-skills@busirocket-tailwindcss-v4 --yes -a <tools>
npx skills add sickn33/antigravity-awesome-skills@radix-ui-design-system --yes -a <tools>
```

Replace `<tools>` with the actual `-a` flags for the user's selected tools (e.g., `-a claude-code -a cursor`).

**If user works on Orchestration (`orchestration/`):**

Install nothing here by default. **That repo ships its own domain skills** and they load the moment
it is cloned — `orchestration/.agents/skills/` symlinked into `.claude/skills/`, five of them:
`pipeline-change`, `platform-flow`, `mart-loader`, `metric-lineage`, `prefect-audit-load`. They are
listed with load-triggers in `orchestration/AGENTS.md` § Skills. Do not install community
duplicates over them.

Tell the user those five exist and when each fires — `metric-lineage` in particular answers "do we
have metric X / why is this column empty" and is the one people most often don't know is there.

If they want more, search rather than guess at package names:

```bash
npx skills find clickhouse
npx skills find "data pipeline"
npx skills find sql
```

> **Note:** Some skills need full URL + `--skill` flag (e.g., `awesome-copilot`). Others use `owner/repo@skill-name` syntax. Browse more at [skills.sh](https://skills.sh/) or search: `npx skills find <query>`.

## Step 11: Configure MCP Servers

Each tool reads MCP config from a different path:

| Tool | Config File |
|------|-------------|
| Claude Code | `.mcp.json` (repo root) |
| OpenCode | `opencode.json` (repo root) |
| Cursor | `.cursor/mcp.json` |
| Amp | `.amp/settings.json` (under `amp.mcpServers` key) — confirm exact path/key with user during install, Amp also supports user-level `~/.config/amp/settings.json` |

### Required MCPs — configure ONE AT A TIME

See [references/mcp-configs.md](references/mcp-configs.md) for per-tool config templates.

**1. Context7** (no credentials needed — just configure and move on)
- Add to MCP config for the user's tool(s)

**2. Agentation** (no credentials needed — just configure)
- Visual UI feedback → structured context for the agent. See [agentation.com/mcp](https://www.agentation.com/mcp).
- Package: `agentation-mcp` (command: `npx -y agentation-mcp server`)
- Add to MCP config for ALL user-selected tools (Claude Code, Cursor, OpenCode, Amp)
- Fastest path: `npx add-mcp "npx -y agentation-mcp server"` auto-detects installed tools and writes the correct config to each

**3. GitHub MCP** — requires a Personal Access Token. Use the ask tool:

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

**4. Laravel Boost** (API only, no credentials needed — just configure)
- Only configure if user selected API service

### Optional MCPs — ask ONE AT A TIME (based on Step 1 answers)

Only configure MCPs the user selected in Step 1.5. For each one that needs credentials, **STOP and WAIT** for the token.

**Prefect MCP** (only if Orchestration was selected — no credentials needed):
- Read-only inspection of the shared Prefect estate: deployments, flow runs, logs, work pools.
- `uvx prefect-mcp-server` with `PREFECT_PROFILE=frndos_prefect` pinned in `env`. That pin is the
  safety mechanism — it fixes the server to one estate for its lifetime.
- **Requires Step 6b to have completed** (`~/.prefect/profiles.toml` must carry the profile), so
  configure it after 6b, not before. Without the profile the server starts and every call errors.
- The three flow-run-mutating tools are denied in `.claude/settings.json` — do not remove them.

**ClickHouse MCP** (only if Orchestration or Data Service was selected — no credentials needed):
- Remote HTTP server, browser OAuth on first use. Read access to the warehouse.
- Destructive SQL still needs explicit operator confirmation every time.

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

# Orchestration: NO server and NO health endpoint by design — do not curl it.
# The install proof is that the suite COLLECTS: collection exercises the venv, the
# deps and the import path, which is exactly what onboarding is responsible for.
# It is deliberately NOT "the suite passes" — `main` carries one known failing test
# (test_fb_pages_swap.py::test_substitution_order_when_reel_branch_real_with_inner_empty):
# staging 1 failed / 236 passed, main 1 failed / 206 passed, measured 2026-08-27 on
# both 3.12 and 3.14. A pass/fail check would tell every new developer their install
# is broken when it is not.
# No PYTHONPATH prefix is needed — pyproject.toml sets `pythonpath = ["."]`.
if [ -d "orchestration" ]; then
  ( cd orchestration
    if .venv/bin/pytest --collect-only -q >/dev/null 2>&1; then
      echo "✓ Orchestration (imports resolve — no server by design)"
      .venv/bin/pytest 2>&1 | tail -1 | sed 's/^/  suite: /'
    else
      echo "✗ Orchestration — collection failed; check .venv and requirements-dev.txt"
    fi )
fi

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

If you selected Orchestration, read these three before your first change — in order:
  1. orchestration/docs/START-HERE.md   — plain-language tour, ~10 min, no jargon
  2. orchestration/AGENTS.md            — 18 hard rules; rule 1 is "never push to main"
  3. orchestration/docs/pipeline-map.md — per-platform chains, env routing, and how to
                                          debug backwards from a Prefect flow-run id

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
