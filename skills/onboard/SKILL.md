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
  "services": ["api", "web", "ai-service", "data-service"],
  "tools": ["claude-code", "cursor"],
  "claude_session_mode": "agent|team",
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
    "ch_local": "completed|pending",
    "prefect_local": "completed|pending",
    "prefect_setup": "completed|skipped|pending",
    "db_gui": "completed|skipped|pending",
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
    "data-service": "completed|pending",
    "orchestration": "n/a"
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

> **`orchestration` is exempt from the `.env` gate, and the exemption needs two fields, not one.**
> It has no `.env` at all — its credentials are Prefect Secret blocks (Step 6b) — so neither
> `"pending"` (nothing can ever resolve it) nor `"completed"` (no file was ever provided) is true.
> Its `env_status` is therefore the literal string **`"n/a"`**.
>
> **`env_status` is descriptive; the gate reads `steps.env_files`.** `/workflow start` blocks on
> `steps.env_files == "completed"` (see `skills/workflow/SKILL.md` → `/workflow start`, step 1) — a
> single aggregate string, *not* the per-service `env_status` map. So:
>
> - Set `env_status.orchestration` to `"n/a"` so the per-service picture is honest.
> - **Compute `steps.env_files` over the services that actually need a file** — treat `"n/a"` as
>   satisfied. If every other selected service is `"completed"`, `steps.env_files` is `"completed"`.
>
> Get the second bullet wrong and `/workflow start` blocks forever for anyone who selects
> Orchestration, while `.onboard-state.json` looks perfectly correct — the failure is invisible.
>
> ⚠️ **`.onboard-state.json` has no JSON schema** (`workflow/state-schema.json` covers
> `.workflow-state.json` only), so nothing rejects a bad value here and nothing enforces the rule
> above. It holds only because this file and `skills/workflow/SKILL.md` both say so. Any new
> `env_status` value must be handled at every reader, and the readers are:
> `skills/workflow/SKILL.md`, `agents/fragments/session-protocol.core.md`, `skills/jj-workflow/SKILL.md`.
>
> **Two of the four new steps are required parts of onboarding; two are not.** None of them adds a
> `/workflow start` gate — the blocking list above is unchanged — but "does not block the gate" is
> **not** the same as "offer to skip it". Do not present a required step as a choice.
>
> **Required whenever the owning service was selected — no skip option, no `"skipped"` value:**
> - `steps.ch_local` — the local ClickHouse cluster (Step 7.4: server, bootstrap, schema, seed).
>   Required for **data-service and/or orchestration**. It is that pair's equivalent of the API's
>   database: orchestration writes `frnd_agg_marts.*` into it and data-service reads them out, so
>   without it a data developer has no database at all.
> - `steps.prefect_local` — the **local** Prefect estate (Step 7.5: server, blocks, work pool,
>   worker, smoke test). Required for **orchestration**. Every value it needs is pure-local; there
>   is nothing to request from anyone, so there is nothing to wait for and nothing to skip.
>
> **Genuinely optional — keep the skip path:**
> - `steps.prefect_setup` — `~/.prefect/profiles.toml` for the **shared** estate (Step 6b **only**).
>   It carries a credential that must be handed over by fahmi, so a developer may legitimately not
>   have it yet. Orchestration work continues without it: reading flows, editing transforms, running
>   the test suite, and everything in Step 7.5. Only *inspecting the shared estate's* real flow runs
>   needs it. Warn, don't block, and never let skipping it imply skipping Step 7.5.
> - `steps.db_gui` — the database GUI client (Step 9.6). Convenience only.

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
orchestration *writes* `frnd_agg_marts.*`, data-service *reads and serves* them. "Why is this metric
empty?" is answered in orchestration far more often than in data-service, and adding a metric is a
**two-repo change** — the projection that computes the column lives in orchestration, the endpoint
that exposes it lives in data-service. Taking data-service alone leaves half of every data question
invisible.

**Also started automatically by `run-all.sh`:**
- **API Queue Worker** — processes background jobs (always runs with API)
- **Mailhog** — captures emails sent by the API for local testing (:1025 SMTP, :8025 UI)

**Orchestration is deliberately NOT in `run-all.sh`.** It has no long-running process to start
alongside the other services, so there is nothing for `run-all.sh` to health-check — see Step 12.
That is a statement about `run-all.sh`, **not** about setup: if you pick Orchestration, onboarding
sets up a local ClickHouse (Step 7.4) and a local Prefect estate on `:4200` (Step 7.5), and both are
required. You start that server yourself when you work on flows.

### 1.2 Do you have `.env` files ready?

| Service | Env File | Contact |
|---------|---------|---------|
| API | `api/.env` | arhen |
| Frontend | `web/.env.local` | fahrizky, daffa |
| AI Service | `ai-service/.env` | rifki |
| Data Service | `data-service/.env` | fahmi, arhen |
| Orchestration | Prefect Secret blocks — **not** a `.env` ¹ | fahmi |

¹ Orchestration is the one service whose runtime credentials do not live in a `.env`. ClickHouse
host/port/user/password, the data-service callback token and the AWS keys are **Prefect Secret
blocks**, fetched from the Prefect server at flow runtime (`orchestration/AGENTS.md` hard rule 10 —
never print or commit a block value). The committed template is
`prefect_blocks.staging.example.yaml`; the real `prefect_blocks.staging.yaml` is gitignored. Setup
script: `scripts/setup_staging_blocks.py`, dry-run by default. Full procedure: **Step 6b**.

> ⚠️ `orchestration/AGENTS.md` and `integrations/clickhouse.py` both reference
> `prefect_blocks.example.yaml` and `scripts/setup_prefect_blocks.py`. **Neither has ever existed in
> that repo.** Use the `staging` names above; do not go looking for the ones the docs name.

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

### 1.5 Which AI provider subscriptions?

- Anthropic: Claude Opus 5 (planning), Claude Sonnet 5 (coding)
- OpenAI: GPT-5.3-Codex (coding), GPT-5.6 (exploratory)

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

Direct install on macOS via Homebrew. This is the only supported path — every tool is installed directly on the machine.

---

### Install and verify toolchain

#### 2.1 Check what’s installed and version status

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

#### 2.2 Install or upgrade tools

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

**Data-stack tools — Orchestration and/or Data Service only.** Skip this table entirely if the user
selected neither.

| Tool | Check | Action |
|------|-------|--------|
| ClickHouse ¹ | `command -v clickhouse` | Missing → `brew install --cask clickhouse`. Installed → keep |
| Python 3.12 ² | `command -v python3.12` | Missing → `brew install python@3.12`. Installed → keep |

¹ **It is a Homebrew `--cask`, not a formula.** `brew install clickhouse` fails with
`No available formula`, and `clickhouse-cpp` is a C++ client *library*, not the CLI. Verified
2026-09-03: the cask resolves to **26.8.2.7-lts**. The official single-binary installer from
`clickhouse.com` (`curl https://clickhouse.com/ | sh`) is an equally valid route and is what produces
the `clickhouse` binary people often already have in `~/.local/bin` — if `command -v clickhouse` finds
one, keep it and do not install a second.

> **One binary is both client and server.** `clickhouse client` connects to a cluster;
> `clickhouse server` runs one. That is why there is no separate client package. The local server is
> set up in **Step 7.4**, not here — this row only guarantees the binary exists.
>
> **This row is the macOS route.** ClickHouse has no native Windows build — Windows installs inside
> **WSL2**, and Linux uses the distro packages. Both are in Step 7.4.2; the `brew` line above does
> not apply there.

² **Orchestration's deployed Prefect worker runs Python 3.12**, and `orchestration/pyproject.toml`
pins `target-version = "py312"` with a comment stating it matches *"the runtime this repo actually
deploys on — not the interpreter that happens to be on a contributor's PATH."* Note that brew's
`python@3.12` is **keg-only**: installing it does **not** relink `python3`, so `python3` may still be
a different version. Step 5.1 resolves `python3.12` explicitly for that reason.

#### 2.3 Verify all versions after install

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

#### 2.4 Start database services (if not already running)

```bash
# Start PostgreSQL (use whatever version is installed)
brew services start postgresql@$(psql --version 2>/dev/null | grep -oE '[0-9]+' | head -1) 2>/dev/null || brew services start postgresql

# Start Redis
brew services start redis

# Verify
pg_isready -h localhost -p 5432 && echo "✓ PostgreSQL running" || echo "✗ PostgreSQL not running"
redis-cli ping && echo "✓ Redis running" || echo "✗ Redis not running"
```

#### 2.5 Install pgvector extension

```bash
# pgvector for AI service vector search
psql -h localhost -p 5432 -d postgres -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || echo "pgvector may need manual install: brew install pgvector"
```

#### 2.6 Verify all tools

```bash
php --version && composer --version && bun --version && node --version && python3 --version && uv --version && psql --version && redis-cli --version
```

All tools must be available. If any are missing, troubleshoot before continuing.

---

### Record and continue

Mark `steps.prerequisites` as `"completed"` in `.onboard-state.json` and proceed to Step 2.5.

## Step 2.5: JJ (Jujutsu) Setup — Terminal-based harnesses only

**Skip this step entirely unless Amp or Claude Code was selected in Step 1.3.**

Rationale: JJ workspaces are the parallel-feature story for terminal harnesses (Claude Code, Amp). Cursor and OpenCode alone don't need JJ (IDE-integrated / per-session), so they don't trigger this step.

JJ enables parallel feature development via isolated workspaces — useful when you run one agent session per directory. It runs in colocated mode alongside git — all git commands remain unchanged.

**Do not push JJ during setup.** Parallel workspaces only pay off once the user is actually running more than one feature at a time, which never happens on day one. Onboarding detects JJ and moves on; installing it is deferred to the moment `/workflow` first offers a parallel workspace. Recommending an extra tool here costs setup time and buys nothing until then.

1. **Check if JJ is available:**
   ```bash
   command -v jj &>/dev/null && echo "✓ jj available: $(jj --version)" || echo "✗ jj not found"
   ```

2. **If JJ is found** (already on the machine):
   - Record `jj_available: true` in `.onboard-state.json`
   - Tell user: "JJ detected — parallel workspaces are available if you want them later via `/jj-workflow init` then `/jj-workflow new <slug>`. Nothing to do now."
   - **Do NOT run `jj git init --colocate` yet** — repos haven't been cloned. The user will run `/jj-workflow init` after clone, if and when they want parallel features.

3. **If JJ is NOT found:** record `jj_available: false` and continue — **no ask, no install prompt.** Tell the user once, as a single line:
   > "JJ (Jujutsu) isn't installed. It's only needed for working on several features in parallel — skipping it for now. `/workflow` will offer to set it up the first time that comes up."

   Do not present install/skip options and do not run `brew install jj` at this stage.

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
echo "OK" | claude -p --model claude-opus-5 2>&1 | head -1
echo "OK" | claude -p --model claude-sonnet-5 2>&1 | head -1
```

**OpenCode:**
```bash
opencode run -m anthropic/claude-opus-5 "respond with just OK" 2>&1 | head -5
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

# Orchestration — the transform layer (raw -> staging -> frnd_agg_marts).
# Standard branch shape: `development` is the working base. See the warning
# below — what differs is that there is no deploy step.
[ -d "orchestration" ] || (git clone https://github.com/alva-intelligence/frnd-orchestration.git orchestration && cd orchestration && git checkout development)
```

> **Why orchestration is worth cloning even if you never edit it.** The marts every dashboard reads
> are produced here — data-service *serves* them. So "why is this metric empty?" is usually answered
> in this repo, and adding a metric is a **two-repo change**: the projection that computes the column
> lives here, the endpoint that exposes it lives in data-service. Without this clone, half of every
> data question is invisible.

> ⚠️ **Both branches are live Prefect estates, and there is no deploy step.** The branch shape is
> the standard one — `development` is the staging estate, `main` the production one. What differs: a
> Prefect worker polls each estate and `git clone`s the branch **at run time**, so a merge is live
> the moment it lands. There is no build or release to forget about.
>
> **Feature work branches from `development` and PRs into `development`.** Promotion is a **separate
> PR (`development` → `main`)**, opened deliberately by a human, never as part of a feature. Open the
> PR and stop either way: never merge it yourself, and never push directly to `development` or
> `main`.

## Step 5: Install Dependencies

**The agent MUST run these commands directly** — all tools (php, composer, bun, python3, uv) were installed in Step 2 and are on `PATH`.

**Run sequentially, one service at a time. Do NOT ask user to run these manually.**

### 5.1 Set up Python virtual environments FIRST (AI Service + Data Service)

These must exist before installing Python deps:

```bash
# AI Service — uses uv for venv
cd ai-service && uv venv && cd ..

# Data Service — uses standard venv as .venv
cd data-service && python3 -m venv .venv && cd ..

# Orchestration — standard venv as .venv, on Python 3.12 (the deployed worker's runtime).
# `python3` is NOT reliably 3.12: brew's python@3.12 is keg-only and does not relink
# `python3`, so a bare `python3 -m venv` silently builds on whatever is first on PATH.
PY312="$(command -v python3.12 || command -v python3)"
cd orchestration && "$PY312" -m venv .venv && cd ..
```

**Orchestration — verify the interpreter before installing anything into it:**

```bash
orchestration/.venv/bin/python --version
```

> ⚠️ **If that is not 3.12, say so and ask the user before continuing.** The deployed Prefect worker
> runs 3.12 and `orchestration/pyproject.toml` pins `target-version = "py312"`. A newer interpreter
> installs and runs fine today, so the divergence is **silent** — which is exactly why it is worth
> catching here rather than in a production-only failure later. If `python3.12` is absent, Step 2's
> data-stack table installs it.
>
> ⚠️ `orchestration/README.md` says `python -m venv venv` (no dot). Use **`.venv`** so the path
> matches ai-service and data-service, and so the editor tooling in Step 9 finds it.

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

# Orchestration (venv already created in 5.1) — BOTH files: requirements-dev.txt carries
# pytest and ruff, and the runtime install deliberately omits them.
cd orchestration && source .venv/bin/activate && pip install -r requirements.txt -r requirements-dev.txt && deactivate; cd ..
```

> **Orchestration — confirm `prefect` actually landed.** It is the only service whose CLI the rest of
> onboarding calls by path, and nothing later installs it:
>
> ```bash
> orchestration/.venv/bin/prefect version | head -3
> ```
>
> `orchestration/requirements.txt` pins `prefect>=3.0.0` — an **open upper bound**, so a fresh install
> takes the newest 3.x and two machines onboarded a month apart will not match. If this line errors,
> Step 6b and every command in Step 7.5 fails with command-not-found.
>
> The same file also pins `alembic==1.19.1`, `SQLAlchemy==2.0.52` and `clickhouse-sqlalchemy==0.3.2`
> **exactly** — `alembic/env.py` uses Alembic's private `context.get_context()._version`, so a minor
> bump can break every mart migration. Do not loosen them.

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
> | Data Service | `data-service/.env` | fahmi, arhen |
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

> **Computing `steps.env_files` when Orchestration is selected.** Aggregate over the services that
> actually need a file: a service whose `env_status` is `"n/a"` counts as **satisfied**, not pending.
> Orchestration has no `.env` (Prefect Secret blocks — Step 6b), so if every other selected service
> is `"completed"`, `steps.env_files` is `"completed"`. This is the field `/workflow start` gates on;
> treating `"n/a"` as unresolved blocks the workflow permanently for no real reason.

**If "No, I'll get them later":**
- Mark all `env_status.<service>` as `"pending"`
- Tell user: "Contact the service owners listed above. `/workflow start` will block until all .env files are provided."
- Continue onboarding with remaining steps

**The user can continue onboarding with missing .env files, but `/workflow start` will block until ALL are provided.**

## Step 6b: Prefect profiles for the **shared** estate — **STOP** (Orchestration only)

**Skip this entire step if the user did not select Orchestration.**

> **This step is optional, and it is the only optional Prefect step.** It configures access to the
> team's **shared** estate. The **local** estate is Step 7.5, it needs no credential from anyone, and
> it is **required** — skipping this step never means skipping that one.

Orchestration is the one service with **no `.env`**. Its runtime credentials are Prefect Secret
blocks fetched from the server at flow time, and the server connection itself comes from a profile
file that lives **outside the workspace**. Two artifacts, two different places:

| Artifact | Path | Contains | Source |
|---|---|---|---|
| Prefect profiles | `~/.prefect/profiles.toml` (**outside the repo**) | API URL + auth string per estate | the team's shared `secrets` folder — ask fahmi |
| Secret blocks | on the Prefect server, not on disk | ClickHouse host/port/user/pass, callback token, AWS keys | created in Step 7.5.3 |

**Local-only developers can skip the profile entirely.** Step 7.5 stands up a local Prefect server
and creates its blocks with pure-local values — nothing secret, nothing to ask anyone for, and it
runs either way. The profile below is only needed to *read* the shared estate (inspecting real flow
runs and deployments).

### 6b.1 Profiles — ask, then wait

The committed placeholder template is `orchestration/config_handover/profiles.toml.example`. The
real file is **not** in the repo and must never be committed.

Use the ask tool:

> "Orchestration can connect to the team's shared Prefect estate to inspect real flow runs. That
> needs `~/.prefect/profiles.toml`, which carries the server URL and an auth string. Do you have it?"
> - Yes — I have the file (or the values)
> - No — I need it from fahmi
> - Skip — local-only development is fine for now
>
> Say plainly, in the same message, that the answer only affects access to the **shared** estate and
> that the local estate in Step 7.5 is set up regardless.

If **"No"**: tell the user to ask **fahmi** for the shared `profiles.toml`. Mark
`steps.prefect_setup` as `"pending"` and continue — this does not block anything.

If **"Skip"**: mark `steps.prefect_setup` as `"skipped"` with the reason, and continue. **Step 7.5
still runs — it is not optional and this answer does not affect it.**

If **"Yes"**: **the user puts it in place themselves — the agent must not write this file.** It
contains a plaintext credential for a shared estate and it lives outside the workspace.

```bash
# The USER runs this, not the agent:
mkdir -p ~/.prefect
cp "<downloaded>/profiles.toml" ~/.prefect/profiles.toml
chmod 600 ~/.prefect/profiles.toml
```

### 6b.2 Verify — read-only, never mutate

```bash
cd orchestration
.venv/bin/prefect profile ls                                     # expect: frndos_prefect, local
PREFECT_PROFILE=frndos_prefect .venv/bin/prefect deployment ls
```

Any deployment output means the profile works.

> `prefect` is installed **into `orchestration/.venv`** by `requirements.txt` (Step 5.2). Every
> Prefect command in this skill is written as `.venv/bin/prefect` for that reason. On a fresh machine
> a bare `prefect` fails with command-not-found; on a machine that already does data work it may
> resolve to a **different install at a different version** reading the same profiles file. The bare
> name is not the program this skill means.

> ⚠️ **Never run `prefect profile use` or `prefect config set`.** Both rewrite
> `~/.prefect/profiles.toml` **globally** and silently retarget every later Prefect command on the
> machine — including the user's own terminal, and including commands that reach production. Pin the
> profile per command with the `PREFECT_PROFILE=` prefix, every time. Both are denied in
> `.claude/settings.json`; if one prompts, that is the guard working — ask, do not route around it.

### 6b.3 Record

Set `steps.prefect_setup` to `"completed"`, `"pending"` or `"skipped"`. **This field covers this step
only** — the local estate is recorded separately as `steps.prefect_local` in Step 7.5.

**This does NOT block `/workflow start`** — unlike the API's database dump. Orchestration work is
possible without a *shared*-estate connection: reading flows, editing transforms, running the test
suite (`.venv/bin/pytest` — no `PYTHONPATH=` prefix needed, `pyproject.toml` sets `pythonpath`), and
running flows locally against Step 7.5's estate. Only inspecting the shared estate's real flow runs
needs it. Warn, don't block.

## Step 7: Initialize Local Databases & Services

### 7.1 Ensure PostgreSQL is running

Step 2.4 already started PostgreSQL via `brew services`. Verify, and fall back to a workspace-local data directory if the brew service is unavailable:

```bash
if pg_isready -h localhost -p 5432 &>/dev/null; then
  echo "✓ PostgreSQL running (brew service)"
else
  # Fallback: workspace-local data directory (one-time init)
  if [ ! -d ".pgdata" ]; then
    initdb -D .pgdata
    echo "✓ PostgreSQL data directory created at .pgdata/"
  fi
  mkdir -p .logs
  pg_ctl -D .pgdata -l .logs/postgresql.log start
  sleep 2
  pg_isready -h localhost -p 5432
fi
```

Enable pgvector (idempotent, for AI service vector search):

```bash
psql -h localhost -p 5432 -d postgres -c 'CREATE EXTENSION IF NOT EXISTS vector;' 2>/dev/null || echo "pgvector may need manual install: brew install pgvector"
```

### 7.2 Ensure Redis is running

```bash
if redis-cli ping &>/dev/null; then
  echo "✓ Redis running"
else
  mkdir -p .logs
  redis-server --daemonize yes --logfile .logs/redis.log
  redis-cli ping
fi
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

### 7.4 Local ClickHouse — **required for Data Service and/or Orchestration**

**Skip this entire section if the user selected neither. If either was selected, this section is
required — do not offer it as a choice and do not ask whether the user wants it.** The only questions
in it are about *how* to proceed on a machine that already has a cluster (7.4.1), never *whether* to.

This is the ClickHouse equivalent of 7.1's PostgreSQL setup, and it is **shared**: orchestration
writes `frnd_agg_marts.*` into this cluster and data-service reads them out. Set it up once, for both.

> **Why this step exists.** `data-service` documents a local ClickHouse in its own `README.md` §4 and
> orchestration's raw seeder refuses to run against anything else — but onboarding has never set one
> up. So a data developer got a `.env` pointing at a shared remote cluster and no local database at
> all. `api` gets `initdb`, a dump, `artisan migrate` and a blocking gate; ClickHouse got nothing.

> ⛔ **The agent does not execute anything against the cluster — the user does.**
> `Bash(clickhouse client:*)` and `Bash(clickhouse-client:*)` are denied in `.claude/settings.json`,
> because a `clickhouse client --query "…"` invocation carries **arbitrary SQL as its payload**: the
> permission pattern cannot tell a `SELECT` from a `DROP`, and the sub-steps below create users, grant
> privileges and apply DDL.
>
> So follow `references/external-steps.md` for each: **tell the user exactly what to run, ask, wait,
> verify what you can see, do not skip.** The agent may read `.sql` files, count them, check paths and
> `curl` the HTTP endpoint — it may not execute SQL. If a `clickhouse client` call prompts, that is
> the guard working: ask, do not route around it.

#### 7.4.1 Probe first — never propose before you know what exists

**Run all three before deciding anything.** A developer who already does data work on this machine
very likely has some of this already, and the wrong move is to install a second copy or re-apply
schema over a working cluster.

```bash
# 1. Is the binary present, and where?
command -v clickhouse && clickhouse client --version || echo "no clickhouse binary"

# 2. Is a server already listening? (agent CAN run this — plain HTTP, no SQL payload)
curl -s --max-time 3 http://localhost:8123/ping || echo "no server on :8123"

# 3. What is already in it? — USER runs this one
clickhouse client --query "SHOW DATABASES"
```

**Then branch on the result. Report what you found before proposing the next step.**

| Probe result | What to do |
|---|---|
| No binary, no server | Install (Step 2 data-stack table), then 7.4.2 → 7.4.3 → 7.4b → 7.4c |
| Server up, **no** `frnd_*` databases | Skip install. Continue at 7.4.3 (bootstrap) |
| Server up, `frnd_agg_marts` / `frnd_os_master` **already present** | **Confirm and ask — see below. Never wipe.** |

**If the cluster already has the databases**, tell the user exactly what was found (database names and
whether `alembic_version` exists in each), then use the ask tool:

> "You already have a local ClickHouse with `<names>`. What would you like to do?"
> - **Bring the schema up to date** (Recommended) — run the Alembic check in 7.4b; it adopts an
>   existing cluster with `stamp` and applies only what is genuinely missing
> - **Add the seed data only** — skip schema, jump to 7.4c, so your local data matches the team's
> - **Leave it alone** — record and move on

Nothing in this section drops a database, truncates a table, or rewrites existing rows.

#### 7.4.2 Install and start a local server

Only needed if the probe in 7.4.1 found no server. The server binds `:8123` (HTTP) and `:9000`
(native), and the terminal running it stays open.

Verify once it is up — the agent can run the `curl`, the user runs the client:

```bash
curl -s http://localhost:8123/ping                  # expects "Ok."  (agent)
clickhouse client --query "SELECT version()"        # (user)
```

**Pick the install route by OS.** Every route below gives you the same `:8123` HTTP endpoint; only
the packaging differs. Detect with `uname -s` — `Darwin` = macOS, `Linux` = Linux (**or WSL**), anything
else means you are on native Windows tooling.

#### macOS — native binary (default)

```bash
brew install --cask clickhouse    # or: curl https://clickhouse.com/ | sh
clickhouse server                 # keep this terminal open
```

One binary is both client and server. This is what `data-service/README.md` §4 documents.

#### Linux — distro packages

```bash
sudo apt-get install -y clickhouse-server clickhouse-client
sudo systemctl start clickhouse-server
```

#### Windows — WSL2 (the official path; there is **no** native installer)

> ⚠️ **ClickHouse ships no native Windows build.** There is no `.exe`, no MSI, and no Windows
> binary — official support is Linux and macOS only, and ClickHouse's own Windows page says to run
> the install *inside WSL*. Native Windows remains open upstream with no timeline
> ([ClickHouse/ClickHouse#86093](https://github.com/clickhouse/clickhouse/issues/86093)). So on
> Windows the "native installer" is **WSL2**: a real local Linux kernel, not a container runtime.

```powershell
# 1. PowerShell as Administrator — one time, then reboot if prompted
wsl --install -d Ubuntu
```

```bash
# 2. Inside the Ubuntu shell — install and run ClickHouse
curl https://clickhouse.com/ | sh
./clickhouse server                 # keep this WSL terminal open
```

WSL2 forwards `localhost`, so `:8123` and `:9000` are reachable from Windows itself — a GUI client
(Step 9.6) and a data-service running on Windows both connect to `localhost:8123` unchanged. Verify
from PowerShell:

```powershell
curl.exe -s http://localhost:8123/ping    # expects "Ok."
```

> If `localhost` forwarding does not work (older WSL builds, or `networkingMode=mirrored` disabled),
> get the WSL IP with `wsl hostname -I` and use that instead of `localhost` in the GUI and in
> `data-service/.env`'s `CH_HOST`.

**PostgreSQL on Windows, for contrast, *does* have a real native installer** — the EDB installer
from postgresql.org. It is a normal Windows service; no WSL needed. Only ClickHouse forces WSL.

#### Docker — last resort, any OS

Only when the routes above are unavailable (locked-down machine, or you already run everything in
containers). It works everywhere but adds a runtime nothing else in this workspace needs:

```bash
docker run -d --name clickhouse-local \
  -p 8123:8123 -p 9000:9000 \
  -v clickhouse-data:/var/lib/clickhouse \
  -e CLICKHOUSE_USER=default -e CLICKHOUSE_PASSWORD= \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
  clickhouse/clickhouse-server
```

**The macOS and Docker routes are also written up in `data-service/README.md` §4** — send the user
there for those rather than re-documenting. The WSL2 path above is **not** in that README; it is
documented here.

**Local vs remote — the trade-off worth stating up front:**

| Mode | What works | What does not |
|---|---|---|
| **Local server** (recommended) | Everything, including 7.4c's raw seed and a full raw → staging → mart chain offline | Nothing real — it starts empty |
| **Remote cluster** | Querying real data | **Seeding.** `orchestration/scripts/local-seed-raw.py` **refuses any host but `localhost`** by design |

#### 7.4.3 Bootstrap the service user — **user runs this**

**Run this before any mart DDL.** 17 of orchestration's 20 `v2` migrations end in
`CREATE ROW POLICY … TO frndos_data_service`, and `alembic/env.py` calls
`_assert_policy_grantee_exists` which **refuses before any DDL runs** if that user is missing.
ClickHouse DDL is not transactional, so a missing grantee would otherwise leave a mart table live
with no row-level security — and RLS is the only tenant boundary the serving layer has.

`data-service` ships one idempotent file that does the whole job:

```bash
clickhouse client --queries-file data-service/database/bootstrap/setup.sql
```

It creates the `frndos_data_service` user, revokes anything over-granted, and grants exactly what the
service's code paths need. Re-runnable on any environment, so it is safe on an existing cluster.

What the **agent** can verify without executing SQL: that the file exists, and that
`data-service/database/bootstrap/` also contains the numbered `001`–`006` history plus a README (the
consolidated `setup.sql` supersedes them for new setups).

#### 7.4b Schema versioning — Alembic, not a manual apply loop

**This is how an existing cluster is handled safely**, and why the answer to "the developer may
already have the DDL, or an *old* DDL" is Alembic rather than a for-loop over `.sql` files.

**Always pull first.** The revisions are code — a checkout from last month describes last month's
schema:

```bash
cd orchestration && git pull && cd ../data-service && git pull && cd ..
```

**There are two Alembic lineages. They are never merged.** They partition the databases cleanly:

| Lineage | Run from | Owns | Revisions |
|---|---|---|---|
| Marts | `orchestration/` | `frnd_agg_marts` | 24 |
| Master / AI / RAFI | `data-service/` | `frnd_os_master`, `frnd_ai_database`, `temp_telkomsel_rafi` | 24 |

Run the same four-step check **once per lineage**, from that lineage's repo root:

```
Step 1  git pull                    # newest revisions           (done above)
Step 2  alembic heads               # what the repo expects
Step 3  alembic current             # what THIS cluster has
Step 4  branch on the comparison:
          no alembic_version + tables already present  ->  stamp head   (adopt, apply nothing)
          no alembic_version + empty database          ->  upgrade head (build it)
          current == heads                             ->  nothing to do
          current behind heads                         ->  upgrade head (apply only the delta)
```

**Marts lineage — orchestration:**

```bash
cd orchestration
FRND_ENVIRONMENT=staging .venv/bin/alembic heads      # agent may run (read-only)
FRND_ENVIRONMENT=staging .venv/bin/alembic current    # agent may run (read-only)
# then ONE of these — USER runs it:
FRND_ENVIRONMENT=staging .venv/bin/alembic stamp head
FRND_ENVIRONMENT=staging .venv/bin/alembic upgrade head
cd ..
```

> **`FRND_ENVIRONMENT` is an estate label, not a branch name.** It selects which cluster the
> migration lands on (`staging` → the `clickhouse-host-staging` block, anything else → the
> production `clickhouse-host` block). It is unrelated to which git branch you have checked out, and
> it does **not** become `development` when the branch does. Keep `staging` here: it is what points a
> local or staging run away from the production cluster.

**Master lineage — data-service.** `alembic` is **missing from its `requirements.txt`** despite 24
revisions and a committed `alembic.ini`, so install it into that venv first, at orchestration's exact
pins:

```bash
cd data-service && source .venv/bin/activate
pip install alembic==1.19.1 SQLAlchemy==2.0.52 clickhouse-sqlalchemy==0.3.2
.venv/bin/alembic heads && .venv/bin/alembic current
deactivate; cd ..
```

**Warnings that change what happens — state all of these:**

> ⚠️ **`FRND_ENVIRONMENT` unset resolves to PRODUCTION.** `orchestration/alembic/env.py` implements
> `_assert_environment_declared()` precisely because `_is_staging()` is false when the variable is
> unset, and "no marker ⇒ production" is that repo's hard rule 11. It refuses to act from a terminal
> until you name the cluster. **Carry the prefix on every single Alembic command.**

> ⚠️ **An `upgrade` that refuses is the guard working, not a failure.** Both lineages implement
> `_assert_stamped_or_empty`: it refuses to `upgrade` a cluster that already holds tables but has no
> `alembic_version` row, because that would replay the whole chain against a provisioned database.
> The printed remedy is `stamp head` — and `stamp` is deliberately **not** guarded, so the remedy is
> reachable. `stamp` writes the version row and applies **no DDL**: it is how you adopt an existing
> cluster into version control, which is exactly the case here.

> ⚠️ **The two lineages must never be merged**, and only ever run from their own repo root. They are
> indistinguishable at the command line — same binary, same `stamp head` — and only the working
> directory decides which lineage and which cluster you hit. Both `env.py` files print
> `lineage=… | env=… | host_block=…` to stderr before acting, for exactly this reason. Read that line.

> ⚠️ **`data-service/database/README.md` says "Do not use Alembic/Flyway" — that guidance is stale.**
> Its own tree contains `alembic.ini` and 24 revisions. The objection was that Alembic assumes
> transactional rollbacks; here nothing rolls back (`downgrade` is irreversible by construction) and
> Alembic is used purely as an *ordering and tracking wrapper* — each revision runs one `.sql` file
> and records that it ran. The SQL is the same SQL.

> ⚠️ **The two mart DDL trees are not identical, which is the whole reason to use Alembic.** Measured
> 2026-09-03: `orchestration/database/migrations/frnd_agg_marts/` has **58** `.sql` files,
> `data-service/database/migrations/frnd_agg_marts/` has **55**. All 55 shared files are byte-identical
> — but orchestration carries three extra, and they are real `ALTER`s on a shared table:
> `v2/021_add_duration_seconds_to_social_content_performance.sql`, `v2/022_add_skip_rate_3s_…`,
> `v2/023_add_completion_rate_…`. A developer who hand-applies data-service's tree alone ends up with
> three missing columns and no signal why. Orchestration's Alembic chain is the only thing that
> carries them, so **run the marts lineage even if you only work on data-service.**

> **Mart DDL ownership moved to orchestration on 2026-08-26**, but only on the working branches —
> `frnd-orchestration:development` and `frnd-clickhouse-api:development`, **neither repo's `main`**.
> So which copy is authoritative depends on the branch you checked out. Adding a mart column is an
> orchestration change on those branches. Check before you write one.

> **There is no manual migration runner, and you do not need one.** `data-service/database/README.md`
> describes one that "could" live at `database/migrate.py`; it does not exist. Alembic is the runner.
> Do not hand-execute the 93 `.sql` files.

**Also, if you followed a README that had you create the tracker table by hand:** that snippet uses
`ENGINE = SharedMergeTree(...)`, which is **ClickHouse Cloud only** and fails on an OSS server with
`Code: 56 … Unknown table engine SharedMergeTree`. Alembic creates its own `alembic_version` with a
`MergeTree` engine and needs no help. None of the 93 mart/master migrations use a Cloud-only engine
(65 `ReplacingMergeTree`, 14 `MergeTree`, 1 `SummingMergeTree`), so they all run locally.

Record `steps.ch_local` in `.onboard-state.json` — `"completed"`, or `"pending"` if something is
genuinely unresolved. There is no `"skipped"` value for this step.

#### 7.4c Seed — so everyone's local data matches

**Offer this even when the cluster already existed.** Schema without rows renders every dashboard as
em-dashes, which reads as a bug rather than as "no data yet". Seeding is additive and safe to re-run.

**Marts and master data — data-service's Python seeders.** Plain scripts, no runner; from the repo root:

```bash
cd data-service && source .venv/bin/activate
python database/seeders/frnd_agg_marts/v2/000_generate_fake_data.py    # medium-volume base
python database/seeders/frnd_agg_marts/demo/seed_demo.py               # demo workspace + 3 brands
deactivate; cd ..
```

`000_generate_fake_data.py` inserts as the `default` superuser and **does not truncate** — re-running
adds duplicates, which `ReplacingMergeTree` dedups by `ORDER BY`. `seed_demo.py` copies rows from the
realistic brands, rewrites them with the demo ULIDs, shifts every date into a rolling 90-day window
ending today, and applies a per-brand volume multiplier; it auto-generates its source data if absent.
The 30 `.sql` seeders under `database/seeders/frnd_agg_marts/` are the older v1 set — the Python ones
supersede them.

**Raw layer — orchestration's seeder.** Only useful with a **local** server; it refuses any other host.

```bash
cd orchestration
.venv/bin/python scripts/local-seed-raw.py --list
.venv/bin/python scripts/local-seed-raw.py --brand <ulid> --platforms ig --posts 40
cd ..
```

Why it matters: the demo cluster's raw tables are *placeholders* (five columns), so the transforms
have nothing real to read and every downstream metric renders as an em dash. That is an absent source,
not a pipeline bug. This script builds the source with real table shapes derived from
`orchestration/config_handover/*.yaml` — the Fivetran allow-list each transformer reads against — so
**the fixture cannot drift from the pipeline's own expectations**.

> ⚠️ **The demo ULIDs are a cross-repo contract with no shared source.** `seed_demo.py` reads them
> from `data-service/demo-ulids.json`; the api's `DemoWorkspaceSeeder` reads the same values from
> `api/demo-ulids.json`. **Two copies.** If Postgres and ClickHouse demo data disagree, this is why.
> Do not edit one without the other.

### 7.5 Local Prefect estate — **required for Orchestration**

**Skip if the user did not select Orchestration. If Orchestration was selected, this section is
required — do not offer it as a choice and do not ask whether the user wants it.**

> Every value this step needs is **pure-local** (7.5.3): there is no credential to request, nobody to
> wait on, and nothing secret. That is what separates it from Step 6b, which configures the *shared*
> estate and is optional. A "skip" answer in 6b has no bearing here.

**Prerequisite: 7.4 must have produced a running local ClickHouse on `:8123`.** Every flow — the smoke
test included — resolves ClickHouse from Secret blocks and writes to it. Prefect alone starts fine,
but nothing it runs will complete.

**The whole path, so a new developer can see the shape before walking it.** Six sub-steps, three
terminals, roughly 15 minutes:

```
7.5.1  confirm .venv/bin/prefect and the `local` profile        (agent can run)
7.5.2  Terminal 1:  prefect server start    -> http://127.0.0.1:4200   (leave running)
7.5.3  Terminal 2:  create 5 Secret blocks  -> pure-local values, NO secrets needed
7.5.4  Terminal 2:  set the staging_date_cutoff Variable
7.5.5  Terminal 2:  work-pool -> register deployments -> worker start   (leave running)
7.5.6  Terminal 3:  prefect deployment run testing-worker/smoke-testing
```

Terminal 1 and the worker in Terminal 2 both stay running. 7.5.5 and 7.5.6 are **user-run** — those
commands are denied to the agent on purpose, each with the reason stated where it appears.

#### 7.5.1 Confirm the install and the `local` profile

This step installs nothing. Prefect is **not** a system package and has no Homebrew row — it arrives
in `orchestration/.venv` from `requirements.txt` at Step 5.2:

```bash
cd orchestration && .venv/bin/prefect version | head -3
```

Expect `Version: 3.x` and a Python version matching the interpreter Step 5.1 resolved. If it errors,
go back to Step 5.2; nothing below can work.

> ⚠️ **A global `prefect` may already exist, and it is not this one.** A machine that already does
> data work can easily have `~/.local/bin/prefect` at a *different* 3.x version, answering to whatever
> `~/.prefect/profiles.toml` currently defaults to. **Always `.venv/bin/prefect`.** A bare `prefect`
> is a different program reading the same profiles file.

Then confirm a `local` profile exists — don't create one blindly:

```bash
cd orchestration && .venv/bin/prefect profile ls    # expect `local` in the list
```

> If `local` is missing, **the user creates it, not the agent.** The two commands that would do it —
> `prefect profile use` and `prefect config set` — are denied because they rewrite
> `~/.prefect/profiles.toml` globally and silently retarget every later Prefect command on the
> machine, including ones that reach production. Hand the user these two lines and wait:
>
> ```bash
> prefect profile create local
> prefect config set PREFECT_API_URL="http://127.0.0.1:4200/api"
> ```

**Every command below pins the profile with a `PREFECT_PROFILE=` prefix.** That is not style: the
prefix is scoped to one command, `profile use` is not.

#### 7.5.2 Terminal 1 — the local server (leave running)

```bash
cd orchestration && PREFECT_PROFILE=local .venv/bin/prefect server start
```

Serves `http://127.0.0.1:4200`. **This is the one port orchestration can contend for** — it is in the
Step 12 port-conflict check for that reason.

#### 7.5.3 Terminal 2 — five Secret blocks, all pure-local

The flows read **every** credential from Prefect `Secret` blocks, never a `.env`. Create these on the
**local** server via the UI at `http://127.0.0.1:4200` → Blocks → Secret.

> **The server from 7.5.2 must be running before this step and before any flow run.**
> `Secret.load(...)` is an **API call** to `127.0.0.1:4200`, not a file read — with the server down it
> fails and the caller sees an empty value, which reads as a missing block rather than a stopped server.

**Nothing here is secret and there is nothing to ask anyone for.** This is the default for a new
developer: it points every flow at the ClickHouse 7.4 just started on this machine.

| Block | Value | Why |
|---|---|---|
| `clickhouse-host` | `localhost` | `get_client()` passes a bare hostname straight through and defaults to non-TLS. A `https://…` URL is parsed; `localhost` is not. |
| `clickhouse-port` | `8123` | The HTTP port 7.4.2 starts |
| `clickhouse-user` | `default` | The OSS server's superuser |
| `clickhouse-pass` | *(empty string)* | Create it **with an empty value** — do not skip it; `get_client()` loads it unconditionally |
| `environment` | `local` | `resolve_environment()` returns this verbatim, and `local` is what the S3 upload guard checks before short-circuiting |

That set is enough for **7.5.6's smoke test** and for any transform that does not call an external API.

> `clickhouse-host-staging` is loaded **instead of** `clickhouse-host` whenever a staging signal
> fires. For a pure-local estate, set it to `localhost` too, so a stray staging signal cannot reach a
> real cluster.

**Only if you need real external API calls** do you need real secrets — `openai-key`,
`data-service-callback-token`, the four `aws-*`, `github-pat`, `rapid-api-key`. Ask **fahmi**. Never
print, log or commit a block value (hard rule 10).

> **The agent cannot do this step.** `prefect block create` / `delete` are denied, and no script
> creates *local* blocks — `scripts/setup_prefect_blocks.py` and `prefect_blocks.example.yaml` are
> referenced by that repo's own docs but **have never existed**. The only block script in the repo is
> `scripts/setup_staging_blocks.py`, which creates `-staging` siblings on a **remote** estate and is
> not the local path. UI or nothing.

**Confirm what landed** — read-only, the agent can run this:

```bash
cd orchestration && PREFECT_PROFILE=local .venv/bin/prefect block ls
```

Expect the five names above. `block ls` prints names and types only, never values.

#### 7.5.4 The `staging_date_cutoff` Variable

One Prefect Variable gates how far back data is kept project-wide — rows older than it are dropped
from staging, marts and creative assets:

```bash
cd orchestration && PREFECT_PROFILE=local .venv/bin/prefect variable set staging_date_cutoff "2025-01-01"
```

The source of truth is the live Variable on the shared estate; read it any time with
`PREFECT_PROFILE=frndos_prefect .venv/bin/prefect variable get staging_date_cutoff` (needs Step 6b)
and keep local in sync. The hardcoded constant in `tasks/transform_helpers.py` is a last-resort
default only.

#### 7.5.5 Work pool, deployments, worker — **user runs these**

```bash
# Terminal 2
cd orchestration
PREFECT_PROFILE=local .venv/bin/prefect work-pool create local-pool --type process
PREFECT_PROFILE=local .venv/bin/python scripts/register_paid_deployments.py --env production
PREFECT_PROFILE=local .venv/bin/prefect worker start --pool local-pool   # leave running
```

> **On a local server the worker runs the code on your disk.** The register script switches on
> `PREFECT_API_URL`: remote → a fresh git clone pinned to the environment's branch; **local
> (`localhost`/`127.0.0.1`) → the repo root path**, so there is no clone, no branch pin, and an edit
> to a flow is live on the next run. That is what makes a local estate worth standing up.

> ⚠️ **The agent must not run the middle line.** `Bash(*register_paid_deployments*)` is denied on
> purpose: the script takes `--env`, but the **active profile** decides *which server* it writes to —
> so the same command that registers six local deployments will register them against the shared
> production estate if the profile is wrong. `--env production` is correct here: it produces the
> unsuffixed deployment names the local worker expects, and it does **not** mean production. Have the
> user confirm the `PREFECT_PROFILE=local` prefix is present before they run it.

#### 7.5.6 Smoke test — **user runs this**

```bash
# Terminal 3, with the server (7.5.2) and the worker (7.5.5) both still running
cd orchestration
PREFECT_PROFILE=local .venv/bin/prefect deployment run testing-worker/smoke-testing
```

> ⚠️ **The agent must not run this.** `prefect deployment run` is denied in both invocation forms —
> the deployment is chosen by name but the *profile* decides which server hears it, so the same line
> fires a local test or a production flow depending on a prefix. Hand it to the user.

A `Completed` run proves the whole chain in one shot: the worker picked up a deployment, resolved
Prefect Secrets, connected to ClickHouse and wrote to it. It creates its own database
`smoke_prefect_testing` and appends one row per run, stamped with the environment label — safe to
re-run, touches nothing else. Watch it at `http://127.0.0.1:4200`.

Read the result back — the agent can run this (plain HTTP, no SQL client):

```bash
curl -s 'http://localhost:8123/' --data-binary 'SELECT count() FROM smoke_prefect_testing.smoke_test'
```

**If it fails, check in this order:** server running (7.5.2)? worker running and polling `local-pool`
(7.5.5)? all five blocks present (`block ls`)? ClickHouse up (`curl :8123/ping`)? The flow-run page in
the UI shows which of those it got stuck on.

> **Step 12 re-runs this as orchestration's health check**, with a four-probe readiness pass in front
> of it and a symptom→cause table. If you are setting up now, running it once here is enough; Step 12
> is where it becomes the standing verification.

Record `steps.prefect_local` in `.onboard-state.json` — `"completed"`, or `"pending"` if something
is genuinely unresolved. There is no `"skipped"` value for this step. Do **not** write
`steps.prefect_setup` here; that field belongs to Step 6b.

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

> **Auto-mode coverage:** the base template ships with `permissions.allow` covering every command the workflow needs (git, gh, jj, jq, scoped Edit/Write to `docs/` + state files), a `permissions.deny` blocklist for destructive commands, and `autoMode.environment` hints that mark Lark docs as a read-only source and JJ secondary-workspace symlinks as in-scope. This means the workflow runs hands-off under Claude Code's auto mode (`https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode`) without sandbox prompts breaking sub-agents. Users who want to TIGHTEN beyond the defaults should edit `.claude/settings.json` after install; users who want personal additions should put them in `.claude/settings.local.json` (gitignored).

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

1. Copy template: `cp .agents/skills/onboard/references/launch.json .claude/launch.json`
2. Remove entries for services the user didn't select
3. Done — commands run directly (tools in system `PATH`)

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

All commands run directly against tools on `PATH`. Infrastructure services (PostgreSQL, Redis) should start before app services.

## Step 9.6: Database GUI client — **STOP, ask user**

A GUI client is how a developer actually *sees* the local databases Steps 7.1–7.4 just built. Both
engines are involved: **PostgreSQL** (api, `:5432`) and **ClickHouse** (data-service + orchestration,
`:8123`). Run this step for every workspace — it is useful even with only `api` selected.

### 9.6.1 Detect what is already installed

```bash
ls /Applications 2>/dev/null | grep -iE "tableplus|dbeaver|datagrip|beekeeper|postico|pgadmin|sequel" || echo "no GUI client found"
```

Also check Homebrew's view, since a cask can be installed without an `/Applications` entry:

```bash
brew list --cask 2>/dev/null | grep -iE "tableplus|dbeaver|datagrip|beekeeper|pgadmin|sequel-ace" || true
```

### 9.6.2 Ask — **even when one is already installed**

**Name what was found first, then ask anyway.** Never silently skip because something is present, and
never silently install over it. This mirrors how Step 2 handles a pinned tool at the wrong version:
report, then let the user decide.

If a client **was** found, phrase it as an addition:

> "You already have **<name>** installed, which can handle both PostgreSQL and ClickHouse. Want to
> add another client as well?"
> - **No, <name> is fine** (Recommended) — I'll register the local connections in it
> - **TablePlus** — native macOS, fastest, both engines in one window
> - **DBeaver** — free and unlimited, Java-based
> - **DataGrip** — JetBrains, paid, strongest SQL editor

If **nothing** was found:

> "Install a database GUI to browse your local PostgreSQL and ClickHouse?"
> - **TablePlus** (Recommended) — native macOS, fastest, handles Postgres + ClickHouse in one window;
>   free tier covers 2 open connections, which is exactly what onboarding sets up
> - **DBeaver** — free, unlimited connections, Java-based; the only one whose connections this agent
>   can register for you automatically
> - **DataGrip** — JetBrains, paid (or bundled with an All Products Pack); strongest SQL editor
> - **Skip** — I'll use the `psql` and `clickhouse client` CLIs

### 9.6.3 Install the chosen client

```bash
brew install --cask tableplus          # TablePlus
brew install --cask dbeaver-community  # DBeaver
brew install --cask datagrip           # DataGrip
```

All three cask names verified 2026-09-03. If the user picked one already installed, skip the install
and go straight to 9.6.4.

### 9.6.4 Register the two local connections

**Both connections are local and need no credentials**, so nothing secret is written anywhere:
PostgreSQL uses local trust auth (`api/.env` ships `DB_USERNAME=` and `DB_PASSWORD=` empty), and the
OSS ClickHouse `default` user has no password.

| Connection name | Driver | Host | Port | Database | User / password |
|---|---|---|---|---|---|
| `frnd-postgre-local` | PostgreSQL | `localhost` | `5432` | value of `DB_DATABASE` in `api/.env` | *(empty)* / *(empty)* |
| `frnd-ch-local` | ClickHouse | `localhost` | `8123` | `frnd_agg_marts` | `default` / *(empty)* |

> **Register **local only**.** Do not add staging or production connections during onboarding: their
> hosts and passwords are real credentials, and the same rule that keeps them out of a `.env`
> (Step 6b) keeps them out of a GUI config the agent writes.

**The three clients are not equally automatable.** Verified 2026-09-03 — treat them differently rather
than pretending parity:

| Client | Config | Agent can register? |
|---|---|---|
| **DBeaver** | `~/Library/DBeaverData/workspace6/General/.dbeaver/data-sources.json` — **plain JSON** | **Yes.** Passwords live in a separate encrypted file that local connections never need |
| **TablePlus** | keychain-backed; no config dir until first launch | No — guide the user |
| **DataGrip** | JetBrains XML, regenerated on launch; no dir until first run | No — guide the user |

#### DBeaver — the agent registers them, additively

**Preconditions, each checked and reported before touching anything:**

1. `data-sources.json` exists and parses as JSON. If it does not exist, DBeaver has never been
   launched — tell the user to open it once, then re-run this step.
2. **DBeaver is not running:** `pgrep -i dbeaver`. It rewrites this file on quit, so a write while it
   is open is silently discarded. If running, ask the user to close it and wait.

Then merge — **add, never replace:**

```bash
python3 - <<'PY'
import json, os, re, secrets, subprocess
cfg = os.path.expanduser("~/Library/DBeaverData/workspace6/General/.dbeaver/data-sources.json")
doc = json.load(open(cfg))                      # PRESERVE the developer's existing connections
conns = doc.setdefault("connections", {})
existing = {v.get("name") for v in conns.values()}

# Postgres database name comes from api/.env, not a guess.
pgdb = "frnd"
try:
    for line in open("api/.env"):
        if line.startswith("DB_DATABASE="):
            pgdb = line.split("=", 1)[1].strip() or pgdb
except FileNotFoundError:
    pass

# `home` must point at a real local install, resolved not hardcoded.
try:
    bindir = subprocess.run(["pg_config", "--bindir"], capture_output=True, text=True).stdout.strip()
    pghome = os.path.dirname(bindir) if bindir else ""
except Exception:
    pghome = ""

want = [
    ("postgresql", "postgres-jdbc", "frnd-postgre-local", {
        "host": "localhost", "port": "5432", "database": pgdb,
        "url": f"jdbc:postgresql://localhost:5432/{pgdb}",
        "configurationType": "MANUAL", "type": "dev", "auth-model": "native",
        **({"home": pghome} if pghome else {}),
    }),
    ("clickhouse", "com_clickhouse", "frnd-ch-local", {
        "host": "localhost", "port": "8123", "database": "frnd_agg_marts",
        "url": "jdbc:clickhouse://localhost:8123/frnd_agg_marts",
        "configurationType": "MANUAL", "type": "dev", "auth-model": "native",
    }),
]

added, skipped = [], []
for provider, driver, name, conf in want:
    if name in existing:
        skipped.append(name)                    # already there — leave it exactly as it is
        continue
    key = f"{driver}-{secrets.token_hex(8)}"
    conns[key] = {"provider": provider, "driver": driver, "name": name,
                  "save-password": True, "configuration": conf}
    added.append(name)

if added:
    tmp = cfg + ".tmp"                          # atomic: temp in the same dir, then rename
    with open(tmp, "w") as fh:
        json.dump(doc, fh, indent="\t")
    os.replace(tmp, cfg)                        # a failed write leaves the original intact

print("added:  ", added or "(none)")
print("skipped:", skipped or "(none)", "— already present, untouched")
print("total connections now:", len(conns))
PY
```

Then **report exactly what happened** — added vs skipped, and the new total. If both were already
present, "nothing to add" is the correct successful outcome, not a failure.

> **Why merge-and-skip rather than write-and-backup:** the file holds the developer's *other*
> connections, quite possibly including staging and production. The script reads the existing document
> and appends only missing names, so nothing is ever replaced — and because the write is a temp file
> plus `os.replace`, an interrupted write leaves the original file untouched instead of truncated.
> There is no `.bak` to clean up, and no window where the connection list is half-written.

The connection appears with DBeaver's built-in **`dev`** connection type (white label), distinct from
its `test` and `prod` types — so a local connection never visually resembles a production one.

#### TablePlus / DataGrip — guide, do not write

Neither has a safe writable config. Print the table from 9.6.4 as literal values and walk the user
through it once:

1. New connection → choose **PostgreSQL** (or **ClickHouse**).
2. Host `localhost`, Port `5432` (or `8123`), Database as in the table.
3. **Postgres:** leave user and password empty. **ClickHouse:** user `default`, password empty.
4. **Test** / **Test Connection** — it should succeed while the local servers are running.
5. Save with the name from the table, so everyone's connections are named the same.

> If the test fails, the database is not running, not the GUI's fault: `pg_isready -h localhost -p 5432`
> for Postgres, `curl -s http://localhost:8123/ping` for ClickHouse (Step 7.4.2 keeps that terminal open).

### 9.6.5 Record

Set `steps.db_gui` to `"completed"` (installed and/or registered) or `"skipped"` (user declined) in
`.onboard-state.json`. Advisory — it never blocks `/workflow start`.

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

**Lark MCP** (if selected) — read-only: lets `/prd` pull a PRD straight out of a Lark doc URL. Config shape in `references/mcp-configs.md`.

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
for port in 9191 3000 8000 9999 1025 8025 8123 4200; do
  pid=$(lsof -ti :$port 2>/dev/null)
  if [ -n "$pid" ]; then
    echo "⚠ Port $port in use by PID $pid — $(ps -p $pid -o comm= 2>/dev/null)"
  fi
done
```
If any ports are in use, ask user: "These ports are already in use (possibly from another workspace). Should I kill these processes?" Use the ask tool. Only kill after confirmation.

> ⚠️ **`8123` and `4200` are different in kind — do not offer to kill them.** They are the local
> ClickHouse server (Step 7.4.2) and the local Prefect server (Step 7.5.2), which onboarding asked the
> user to leave running in their own terminals. Killing ClickHouse mid-session drops the local cluster
> the marts live in. If either is in use, report it as **expected** and move on.

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

# ClickHouse (only if data-service or orchestration was selected)
curl -sf http://localhost:8123/ping &>/dev/null && echo "✓ ClickHouse (8123)" || echo "○ ClickHouse — not running (start with: clickhouse server)"
```

> **Orchestration has no HTTP health check, by design.** It runs no long-lived server and is absent
> from `run-all.sh`; its flows execute on a Prefect worker. Do not report it as "down" — there is
> nothing to be down.

**Instead, verify the local estate in two tiers.** Tier 1 is four read-only probes the agent runs
itself and is enough for a Step 12 verdict. Tier 2 is the real end-to-end smoke test, which the
**user** fires because triggering a flow run is denied to the agent.

**If Orchestration was selected, Step 7.5 ran, so run both.** Should the estate somehow not be in
place, that is an **unfinished required step, not an opt-out**: say so plainly ("orchestration
selected, local Prefect not configured — Step 7.5 is incomplete"), leave `steps.prefect_local` at
`"pending"`, and tell the user what is left to finish.

#### Tier 1 — agent-run readiness probes (read-only)

```bash
cd orchestration

# 1. Is the local Prefect API up? (the UI at :4200 is the same process)
curl -s --max-time 3 http://127.0.0.1:4200/api/health && echo " ✓ Prefect API" || echo "✗ Prefect API — start it: PREFECT_PROFILE=local .venv/bin/prefect server start"

# 2. Are the five Secret blocks present? (names + types only, never values)
PREFECT_PROFILE=local .venv/bin/prefect block ls

# 3. Is a worker actually polling? A pool with NO healthy worker means runs queue forever.
PREFECT_PROFILE=local .venv/bin/prefect work-pool ls --verbose

# 4. Are the deployments registered?
PREFECT_PROFILE=local .venv/bin/prefect deployment ls
```

Read the results as a chain — each step is meaningless if the one above it failed:

| Probe | Healthy looks like | If it fails |
|---|---|---|
| `/api/health` | any 200 response | Server not started (7.5.2). Everything below is noise until it is. |
| `block ls` | `clickhouse-host`, `-port`, `-user`, `-pass`, `environment` | Blocks missing (7.5.3). Flows will fail at `Secret.load`, reporting an empty value rather than a stopped server — a confusing symptom worth pre-empting. |
| `work-pool ls --verbose` | `local-pool`, type `process`, **READY** | `NOT_READY` means no worker is polling — start it (7.5.5). Runs will sit in `Pending` forever, which looks like a hang, not an error. |
| `deployment ls` | `testing-worker/smoke-testing` among them | Deployments not registered (7.5.5). |

**ClickHouse must also be up**, since every flow writes to it:

```bash
curl -s http://localhost:8123/ping    # expects "Ok."
```

If all five are green, report the estate as **ready** — that is the orchestration equivalent of a
green health check, and it is sufficient for Step 12.

#### Tier 2 — the real smoke test — **user runs this**

Tier 1 proves the plumbing is in place; only an actual run proves it works. `flows/testing_worker_flow.py`
exists for exactly this:

```bash
# Terminal 3, with the server (7.5.2) and worker (7.5.5) both running
cd orchestration
PREFECT_PROFILE=local .venv/bin/prefect deployment run testing-worker/smoke-testing
```

> ⚠️ **The agent must not run this.** `prefect deployment run` is denied: the deployment is chosen by
> name, but the **active profile decides which server hears it** — so the identical line fires a
> local test or a production flow depending on one prefix. Hand it to the user and wait.

**What a `Completed` run proves, in one shot** — this is why it is worth the extra step over Tier 1:

1. The worker picked up a deployment from the pool (scheduling works).
2. `Secret.load` resolved the `clickhouse-*` blocks (the Prefect API answered).
3. `resolve_environment()` returned a label — for a pure-local estate, `local`.
4. The worker connected to ClickHouse **and wrote to it** (`CREATE DATABASE`, `CREATE TABLE`, `INSERT`).

It is **safe to re-run**: it creates its own `smoke_prefect_testing` database, appends exactly one row
per run stamped with the environment label, and touches nothing else — no mart, no staging table.

**Read the result back** — the agent can run these two:

```bash
# Row count climbs by one per smoke run
curl -s 'http://localhost:8123/' --data-binary \
  'SELECT count() FROM smoke_prefect_testing.smoke_test'

# Most recent run, with the environment label it resolved
curl -s 'http://localhost:8123/' --data-binary \
  'SELECT run_id, marker, environment, created_at FROM smoke_prefect_testing.smoke_test ORDER BY created_at DESC LIMIT 1 FORMAT Vertical'
```

> **Check the `environment` column, not just the row count.** A local estate must report `local`. If
> it says `production`, `_is_staging()` resolved false *and* the `environment` block is set to
> production — which means `get_client()` loaded the `clickhouse-host` block. Verify that block points
> at `localhost` before running anything heavier than this smoke test.

**If the run does not complete**, the state tells you which link broke — check in this order:

| Symptom | Cause |
|---|---|
| Stuck in `Pending`, never starts | No worker polling `local-pool` — Tier 1 probe 3 |
| Fails immediately at `Secret.load` | Server down, or a block missing / misnamed — probes 1 and 2 |
| Fails connecting to ClickHouse | CH not running, or `clickhouse-host` points elsewhere |
| `Completed` but the row count did not move | You read a different cluster than the flow wrote to |

The flow-run page in the UI at `http://127.0.0.1:4200` shows the failing task and its traceback
directly — send the user there rather than guessing.

The agent may also inspect run history read-only:

```bash
cd orchestration && PREFECT_PROFILE=local .venv/bin/prefect flow-run ls --limit 5
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
