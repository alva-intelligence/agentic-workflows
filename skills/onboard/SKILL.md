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

| # | Service | Directory | Stack |
|---|---------|-----------|-------|
| 1 | API | `api/` | Laravel 13, PHP 8.5, PostgreSQL, Sanctum + JWT |
| 2 | Frontend | `web/` | Next.js 16, React 19, TypeScript, Tailwind, Bun |
| 3 | AI Service | `ai-service/` | FastAPI, Python, Agno, OpenAI/Anthropic/Google |
| 4 | Data Service | `data-service/` | FastAPI, Python, pandas |

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

---

> **Switch to execution mode now.** The user has answered all questions.
> - **Claude Code:** Exit plan mode (normal mode)
> - **Cursor:** Switch to agent mode
> - **OpenCode:** Switch to Build agent (Tab)
>
> **Create a todo checklist now.** Based on the user's answers, create a task list covering Steps 2–12. Only include items relevant to the services, tools, and providers the user selected. Mark each item as you complete it.

---

## Step 2: Install Nix and Enter Dev Shell

**Nix is REQUIRED. Do NOT fall back to system-installed tools.** All dependencies (PHP, Bun, Node, Python, PostgreSQL, Redis, etc.) are managed through the Nix flake to ensure reproducible builds across all team members.

### 2.1 Check if Nix is installed and flakes are enabled

```bash
command -v nix &>/dev/null && echo "✓ Nix installed: $(nix --version)" || echo "✗ Nix not found"
```

If Nix IS installed, ensure flakes are enabled (idempotent — safe to run multiple times):

```bash
mkdir -p ~/.config/nix
grep -q 'experimental-features' ~/.config/nix/nix.conf 2>/dev/null || echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

Verify flakes work:
```bash
nix flake --help &>/dev/null && echo "✓ Flakes enabled" || echo "✗ Flakes not enabled — check ~/.config/nix/nix.conf"
```

If Nix is installed and flakes work, skip to Step 2.3.

### 2.2 If Nix is NOT installed — **STOP, wait for user**

Nix requires `sudo` and an interactive terminal. The agent CANNOT install it headlessly.

Tell the user (use the ask tool):

> "Nix is not installed. It requires sudo so you must run the installer yourself.
> Please run this in a separate terminal:
>
> ```
> curl -L https://nixos.org/nix/install | sh
> ```
>
> **Let me know when the installation finishes.**"

**DO NOT proceed to the next step.** Wait for the user to confirm Nix is installed. Use the ask tool to ask:

> "Have you installed Nix?"
> - Yes, it's installed
> - Not yet, I need more time
> - I need help with the installation

Only continue when user confirms "Yes". If "Not yet", wait. If "Need help", troubleshoot.

After confirmation, **enable flakes permanently** (no sudo needed, idempotent):

```bash
mkdir -p ~/.config/nix
grep -q 'experimental-features' ~/.config/nix/nix.conf 2>/dev/null || echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

Then verify (use full path if PATH hasn't refreshed):

```bash
# Try PATH first, fall back to full path
NIX_CMD=$(command -v nix 2>/dev/null || echo "/nix/var/nix/profiles/default/bin/nix")
$NIX_CMD --version
```

If still not found, do NOT continue. Ask the user to check their shell path.

### 2.3 Enter the Nix dev shell

The `flake.nix` at the workspace root provides all dependencies. Enter the shell:

```bash
NIX_CMD=$(command -v nix 2>/dev/null || echo "/nix/var/nix/profiles/default/bin/nix")
$NIX_CMD develop
```

This gives you: PHP 8.5, Composer, Bun, Node 22, Python 3.12, uv, PostgreSQL 18 (with pgvector), Redis, gh, git, curl, jq.

### 2.4 Verify tools are available inside the shell

```bash
php --version && composer --version && bun --version && node --version && python3 --version && uv --version && psql --version
```

**If any tool is missing, something is wrong with the flake — do NOT install tools manually.** Fix the `flake.nix` instead.

### 2.5 IMPORTANT: All subsequent steps MUST run inside `nix develop`

Every command from this point forward (deps install, migrations, run-all.sh, etc.) must be run inside the Nix shell. If the user opens a new terminal, they must run `nix develop` again.

> **Do NOT use brew, apt, pip install --global, npm install -g, or any other system package manager.** Everything comes from Nix.

### 2.6 Remind user to restart later

If Nix was freshly installed in this session (using full path), tell the user:

> "Nix is working via the full path for now. **After onboarding is complete, please restart all terminals and start a new agent session** so that `nix` is properly in your PATH for future sessions."

This does NOT block onboarding — continue with the remaining steps. Just remind them at the end.

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

**CRITICAL: Nix shell rules for dependency installation:**

1. **All commands MUST run inside `nix develop`.** If you're in a Claude Code/agent session where `nix develop` wraps your shell, all tools (php, bun, python3, composer, uv) are already available.
2. **NEVER run multiple `nix develop` sessions in parallel.** Nix uses an eval lock — concurrent sessions will deadlock and timeout. Run ONE session, install deps SEQUENTIALLY.
3. **The first `nix develop` may take 5-15 minutes** as Nix downloads all packages. This is normal. Use a long timeout (600s) and DO NOT panic or retry.
4. **If `nix develop` times out**, check if it's still building: `ps aux | grep nix`. If yes, wait. If no, retry once.

Install deps **sequentially in a single shell**, one service at a time:

```bash
# API (inside nix develop)
cd api && composer install --no-interaction && cp -n .env.example .env && php artisan key:generate --no-interaction 2>/dev/null; cd ..

# Frontend
cd web && bun install && cp -n .env.example .env.local; cd ..

# AI Service
cd ai-service && uv venv && uv pip install -r requirements.txt && cp -n .env.example .env; cd ..

# Data Service
cd data-service && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt && cp -n .env.example .env; cd ..
```

**Notes:**
- `cp -n` = don't overwrite if .env already exists (user may have placed real creds)
- `--no-interaction` prevents artisan from prompting
- Run each service one at a time, wait for completion before starting the next

Update `.onboard-state.json`: set `steps.install_deps` to `"completed"`.

## Step 6: Set Up Environment Files — **STOP, ask for EACH service**

The `.env.example` files were copied in Step 5, but they contain placeholder values. **Each service needs real credentials to run.**

**Process EACH selected service ONE AT A TIME.** Use the ask tool for each:

> "Do you have the real `.env` credentials for **[service]**?"
> - Yes, I have them ready
> - No, I'll get them later from [contact]

| Service | Env File | Contact |
|---------|---------|---------|
| API | `api/.env` | arhen |
| Frontend | `web/.env.local` | fahrizky, daffa |
| AI Service | `ai-service/.env` | rifki |
| Data Service | `data-service/.env` | kemal, iru |

**If user says "Yes, I have them":**

1. Tell user: "Please replace the `.env` file now. You can either:
   - Drop/paste the file content into the chat
   - Or place the file manually at `<service>/<env-file>` and tell me when done"
2. **STOP AND WAIT.** Do NOT continue until user confirms they've provided the file.
3. Use the ask tool to confirm:
   > "Have you placed the real `.env` file for **[service]**?"
   > - Yes, it's in place
   > - I need more time
4. Only after confirmation, verify the file is NOT a placeholder:
   ```bash
   # Check for common placeholder patterns
   grep -qE 'your-secret-here|CHANGE_ME|your_.*_key|example\.com|placeholder' <service>/<env-file> && echo "⚠ Still has placeholders" || echo "✓ Looks real"
   ```
5. Mark `env_status.<service>` as `"completed"`

**If user says "No, I'll get them later":**
- Mark `env_status.<service>` as `"pending"`
- Tell user who to contact
- Move to the next service

**IMPORTANT: Do NOT batch all services into one question.** Ask one at a time, wait for the answer, process it, then ask the next. This ensures the user has time to provide each file.

After checking all services:
- If ALL selected services have real .env files → set `steps.env_files` to `"completed"`
- If ANY are pending → set `steps.env_files` to `"partial"` and list what's missing

**The user can continue onboarding with partial .env setup, but `/workflow start` will block until ALL are completed.**

## Step 7: Database Setup — **STOP, ask user**

Use the ask tool:

> "Do you have a PostgreSQL database dump (.dump file) for local development?"
> - Yes, I have the dump file ready
> - No, but I can get it now from arhen
> - No, I'll get it later

**If "Yes, I have the dump file":**

1. Ask user: "Please provide the file path to the dump (e.g., `~/Downloads/frnd-dev.dump`)"
2. **STOP AND WAIT** for user to provide the path
3. Use the ask tool: "Is the dump file ready at the path you provided?"
4. Only after confirmation, proceed with restore:
   ```bash
   createdb frnd 2>/dev/null || true
   pg_restore -d frnd <path> || psql frnd < <path>
   cd api && php artisan migrate --no-interaction; cd ..
   ```
5. Verify: `psql -h localhost -p 5432 -d frnd -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'"` — should return > 0
6. Mark `steps.db_setup` as `"completed"`

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

1. **Check for port conflicts first:**
```bash
for port in 9191 3000 8000 9999; do
  pid=$(lsof -ti :$port 2>/dev/null)
  if [ -n "$pid" ]; then
    echo "⚠ Port $port in use by PID $pid — $(ps -p $pid -o comm= 2>/dev/null)"
  fi
done
```
If any ports are in use, ask user: "These ports are already in use (possibly from another workspace). Should I kill these processes?" Use the ask tool. Only kill after confirmation.

2. Run preflight: `./run-all.sh --check`
3. If preflight passes, start services: `./run-all.sh`
3. Wait 10-15 seconds for services to boot
4. Run health checks for EACH selected service:

```bash
# Check each service that was set up
curl -sf http://localhost:9191/health && echo "✓ API" || echo "✗ API"
curl -sf http://localhost:3000 && echo "✓ Frontend" || echo "✗ Frontend"
curl -sf http://localhost:8000/health && echo "✓ AI Service" || echo "✗ AI Service"
curl -sf http://localhost:9999/health && echo "✓ Data Service" || echo "✗ Data Service"
pg_isready -h localhost -p 5432 && echo "✓ PostgreSQL" || echo "✗ PostgreSQL"
redis-cli ping && echo "✓ Redis" || echo "✗ Redis"
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

You're ready to start building. In your next session:
  /workflow start <feature-slug>    — begin a new feature
  /workflow status                  — check current state

Please restart your agent session now so all skills and agents are properly loaded.
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
