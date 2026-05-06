## Session-time workflow checks

These are the deep procedures referenced from the session-start protocol in `AGENTS.md`. Run them when the protocol calls for them.

### Feature branch recency check (MANDATORY)

After pulling the current branch, check whether each service repo that has a **feature branch** checked out is up to date with its base branch. Stale feature branches cause painful conflicts at PR time, so surface this early.

**For each service directory** (`api/`, `web/`, `ai-service/`, `data-service/`) that exists AND is on a `feature/*`, `fix/*`, or `improvement/*` branch:

1. Determine the **base branch** from the Service Registry (`skills/onboard/references/service-registry.md`):
   - `api/`, `web/` → `develop`
   - `ai-service/`, `data-service/` → `development`
2. Fetch origin and compare:
   ```bash
   cd <service>
   git fetch origin <base-branch>
   behind=$(git rev-list --count HEAD..origin/<base-branch>)
   cd -
   ```
3. If `behind > 0`, the feature branch is missing commits from the base branch. **Do NOT auto-merge or auto-rebase** — this can produce conflicts that require manual resolution.
4. **Use your ask tool** (Claude Code: `AskUserQuestion`; Cursor: ask tool; OpenCode: question tool; Amp: ask as plain text and wait) to surface the situation:

   > "The `<service>` feature branch is **N commits behind `<base-branch>`**. Stale branches often cause conflicts at PR time. Would you like me to:
   > - Merge `<base-branch>` into the feature branch now (default)
   > - Rebase onto `<base-branch>` (rewrites history — only if nobody else is pulling this branch)
   > - Skip for now (I will remind you later)"

5. Only act after an explicit user choice. If the user picks merge/rebase and conflicts arise, fall back to the standard conflict protocol (list files, ask, never resolve silently).

**Recency check after long sessions:** Additionally, re-run this check:
- After any context compaction event
- When resuming a session that has been idle for more than ~1 hour
- Before creating a PR (regardless of how recent the last check was)

When re-running mid-session, again use the ask tool — never merge/rebase silently.

### Service health checks

Only check services that **actually exist** in the workspace. The authoritative list of health commands lives in `skills/onboard/references/service-registry.md`. Quick version:

| Service | Check If Exists | Health Check |
|---------|----------------|-------------|
| API | `api/` directory | `curl -sf http://localhost:9191/api` (any HTTP response = running) |
| Frontend | `web/` directory | `curl -sf http://localhost:3000` |
| AI Service | `ai-service/` directory | `curl -sf http://localhost:8000/health` |
| Data Service | `data-service/` directory | `curl -so /dev/null -w "%{http_code}" http://localhost:9999/api/v1/health/` (200 OR 401) |
| PostgreSQL | `api/` exists | `pg_isready -h localhost -p 5432` |
| Redis | `ai-service/` exists | `redis-cli ping` |

If any required service is DOWN:
- Tell user which services are not running
- Offer: "Should I run `./run-all.sh` to start all services?"
- Or: "Should I start just the specific services needed?"
- Wait for services to be healthy before proceeding

### Update check + sync

**Instruction updates:**
```bash
bash .agentic-workflows/scripts/update-check.sh
```

If the script doesn't exist, bootstrap it:
```bash
curl -sL "https://raw.githubusercontent.com/alva-intelligence/agentic-workflows/main/scripts/update-check.sh" \
  -o /tmp/aw-update-check.sh && bash /tmp/aw-update-check.sh --bootstrap
```

**Pull latest code** (only if inside a git repo with a remote):
```bash
git fetch origin && git pull --rebase origin $(git branch --show-current)
```

If lockfiles changed, update dependencies:
- `bun install` (web — only if `web/` exists)
- `composer install` (api — only if `api/` exists)
- `uv sync` (python services — only if they exist)

If conflicts arise:
1. List ALL conflicted files with a summary
2. Ask user: "There are merge conflicts. Would you like to: (A) resolve them yourself, or (B) let me resolve them?"
3. If user picks B, resolve and show resolution for approval before committing
4. NEVER auto-resolve conflicts silently
