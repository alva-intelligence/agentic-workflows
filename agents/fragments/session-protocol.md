## SESSION START PROTOCOL (MANDATORY)

**This protocol MUST be executed before ANY other work. No exceptions.**

### Step 0: Detect workspace type

Check `.workflow-state.json` for `workspace_meta.is_jj_workspace`:
- If `true` → this is a **secondary JJ workspace**, scoped to one feature. Note this for later — the session is limited to the feature in `workspace_meta.feature_slug`.
- If `false` or absent → this is the **primary workspace** (or a non-JJ workspace). Check `command -v jj` to detect JJ availability for later use (e.g., suggesting `/jj-workflow new` when starting parallel features).

### Step 0.5: Detect workspace state

Check the workspace to determine what's needed:

1. **No service directories** (none of `api/`, `web/`, `ai-service/`, `data-service/` exist):
   → Fresh workspace. Use your **ask tool** to ask the user:
     "This workspace hasn't been set up yet. Would you like to start onboarding now?"
   → If **yes**: Read `.agents/skills/onboard/SKILL.md` and execute the onboarding skill directly in this session.
   → If **no**: Tell user they can run `/onboard` later (may need a session restart for the slash command to appear).
   → Do NOT proceed with workflow commands until onboarding is complete.

2. **`.onboard-state.json` exists and `status` is `"in_progress"`**:
   → Onboarding was started but not fully completed. Check what's missing:
   - Read `env_status` — are all selected services' .env files present?
   - Read `steps.db_setup` — is the database restored?
   - If critical items are missing, tell user:
     "Onboarding is incomplete. Missing: [list items]. Run `/onboard resume` to continue, or `/onboard verify` to re-check."
   - If user wants to proceed anyway with `/workflow start`, **BLOCK** and explain what will fail without the missing items.

3. **`.onboard-state.json` exists and `status` is `"completed"`** (or no `.onboard-state.json` but service directories exist):
   → Workspace is set up. Check for `.workflow-state.json`:
   - If it exists → proceed normally with active features
   - If it doesn't → welcome user with `/workflow start`, `/workflow list`

4. **`.workflow-state.json` exists**:
   → Proceed normally through all steps.

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

If `.workflow-state.json` doesn't exist, no features are active yet.

### Step 3: Sync latest code

Only if inside a git repository with a remote:

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

### Step 3.25: Verify Lark sync is configured (MANDATORY)

Lark sync is **required** for all frndOS workspaces — the team depends on shared visibility of feature state. Before allowing any workflow command, confirm both parts are in place:

1. **lark-cli installed and authenticated with the right scopes.** The canonical required scopes (tasks, docs, docx, base, drive, wiki, offline_access) are defined in `skills/lark-sync/SKILL.md` → "Required scopes". A quick check:

   ```bash
   if ! command -v lark-cli &>/dev/null; then
     echo "MISSING: lark-cli"
   else
     lark-cli auth status 2>&1 | jq -r '
       (.scope // "" | split(" ")) as $s
       | if .identity != "user" then "MISSING: user login"
         elif .tokenStatus != "valid" then "MISSING: valid token (re-run lark-cli auth login)"
         elif ($s | index("task:custom_field:write") | not) then "MISSING: task:custom_field:write"
         elif ($s | index("docs:document.content:read") | not) then "MISSING: docs:document.content:read"
         elif ($s | index("bitable:app:readonly") | not) then "MISSING: bitable:app:readonly"
         elif ($s | index("drive:drive") | not) then "MISSING: drive:drive"
         elif ($s | index("wiki:wiki") | not) then "MISSING: wiki:wiki"
         else "OK"
         end'
   fi
   ```

   If any scope is missing, re-run the canonical `lark-cli auth login --scope '<full list>'` command from `skills/lark-sync/SKILL.md`.

2. **`.lark-sync.json` exists in the workspace root** — this is the runtime GUID map produced by `/lark-sync link` or `/lark-sync bootstrap`.

**If either check fails**, use your ask tool (Claude Code: `AskUserQuestion`; equivalents per harness) to guide the user:

> "This workspace is not connected to the team's Lark tasklist. Lark sync is required so the team can see what everyone is working on. How would you like to proceed?
> - **Link to the team's existing tasklist** (most common) — no GUID needed, the agent auto-discovers by name via `lark-cli task +tasklist-search`
> - **Bootstrap a new tasklist** (first team member / team owner only)
> - **Skip for this session** (BLOCK `/workflow start` and `/workflow next`; you can do read-only work only)"

If the user picks "Link", execute `/lark-sync link` (no GUID argument) directly in this session — the skill auto-discovers the tasklist by name. If the user picks "Bootstrap", execute `/lark-sync bootstrap`. If the user has missing prerequisites (no lark-cli, no auth), walk them through install + `lark-cli config init` + `lark-cli auth login` before the link step — see `skills/onboard/references/mcp-configs.md` for the exact commands.

If the user picks "Skip", record `{"lark_sync_deferred_until": "<next session start>"}` in `.workflow-state.json` so subsequent `/workflow start` / `/workflow next` calls BLOCK with: "Lark sync setup deferred. Run `/lark-sync link <GUID>` before continuing."

**First-time sync for existing workspaces:** `/lark-sync link` also backfills — any feature already in your local `.workflow-state.json` that does not yet have a Lark task gets pushed up in the correct section. You should NOT need to do anything manual for existing features.

### Step 3.5: Feature branch recency check (MANDATORY)

After pulling the current branch, check whether each service repo that has a **feature branch** checked out is up to date with its base branch. Stale feature branches cause painful conflicts at PR time, so surface this early.

**For each service directory** (`api/`, `web/`, `ai-service/`, `data-service/`) that exists AND is on a `feature/*` or `wireframe/*` branch:

1. Determine the **base branch** from the Service Registry fragment:
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

5. Only act after an explicit user choice. If the user picks merge/rebase and conflicts arise, fall back to the Step 3 conflict protocol (list files, ask, never resolve silently).

**Recency check after long sessions:** Additionally, re-run this check:
- After any context compaction event
- When resuming a session that has been idle for more than ~1 hour
- Before creating a PR (regardless of how recent the last check was)

When re-running mid-session, again use the ask tool — never merge/rebase silently.

### Step 4: Service health checks

Only check services that **actually exist** in the workspace:

| Service | Check If Exists | Health Check |
|---------|----------------|-------------|
| API | `api/` directory | `curl -sf http://localhost:9191/health` |
| Frontend | `web/` directory | `curl -sf http://localhost:3000` |
| AI Service | `ai-service/` directory | `curl -sf http://localhost:8000/health` |
| Data Service | `data-service/` directory | `curl -sf http://localhost:9999/health` |
| PostgreSQL | `api/` exists | `pg_isready -h localhost -p 5432` |

| Redis | `ai-service/` exists | `redis-cli ping` |

If any required service is DOWN:
- Tell user which services are not running
- Offer: "Should I run `./run-all.sh` to start all services?"
- Or: "Should I start just the specific services needed?"
- Wait for services to be healthy before proceeding

### Step 5: Route to correct agent

Based on `.workflow-state.json`, automatically delegate to the appropriate `frndos-*` agent for the current phase. Do NOT tell the user to manually invoke an agent — delegate directly.
