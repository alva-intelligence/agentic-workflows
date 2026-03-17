## SESSION START PROTOCOL (MANDATORY)

**This protocol MUST be executed before ANY other work. No exceptions.**

### Step 1: Check for instruction updates

```bash
bash .agentic-workflows/scripts/update-check.sh
```

If the script doesn't exist, bootstrap it:

```bash
curl -sL "https://raw.githubusercontent.com/alva-intelligence/agentic-workflows/main/scripts/update-check.sh" \
  -o /tmp/aw-update-check.sh && bash /tmp/aw-update-check.sh --bootstrap
```

### Step 2: Load workflow state

Read `.workflow-state.json` to determine:
- Which feature is currently active (`active_feature`)
- What phase it's in (`features[active_feature].phase`)
- Who the current worker is (`worker`)

If `.workflow-state.json` doesn't exist, this is a fresh workspace — proceed to onboarding.

### Step 3: Sync latest code

```bash
git fetch origin && git pull --rebase origin $(git branch --show-current)
```

If lockfiles changed, update dependencies:
- `bun install` (web)
- `composer install` (api)
- `uv sync` (python services)

If conflicts arise:
1. List ALL conflicted files with a summary
2. Ask user: "There are merge conflicts. Would you like to: (A) resolve them yourself, or (B) let me resolve them?"
3. If user picks B, resolve and show resolution for approval before committing
4. NEVER auto-resolve conflicts silently

### Step 4: Service health checks

Check which services the current feature touches, then verify they're running:

| Service | Health Check |
|---------|-------------|
| API | `curl -sf http://localhost:9191/health` |
| Frontend | `curl -sf http://localhost:3000` |
| AI Service | `curl -sf http://localhost:8000/health` |
| Data Service | `curl -sf http://localhost:9999/health` |
| PostgreSQL | `pg_isready -h localhost -p 5432` |
| ClickHouse | `curl -sf http://localhost:8123/ping` |
| Redis | `redis-cli ping` |

If any required service is DOWN:
- Tell user which services are not running
- Offer: "Should I run `./run-all.sh` to start all services?"
- Or: "Should I start just the API and Frontend?"
- Wait for services to be healthy before proceeding

### Step 5: Route to correct agent

Based on `.workflow-state.json`, delegate to the appropriate `frndos-*` agent for the current phase.
