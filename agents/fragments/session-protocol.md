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
         elif ($s | index("docx:document") | not) then "MISSING: docx:document (write — needed for PRD wiki sync)"
         elif ($s | index("bitable:app:readonly") | not) then "MISSING: bitable:app:readonly"
         elif ($s | index("drive:drive") | not) then "MISSING: drive:drive"
         elif ($s | index("wiki:wiki") | not) then "MISSING: wiki:wiki"
         else "OK"
         end'
   fi
   ```

   If any scope is missing, re-run the canonical `lark-cli auth login --scope '<full list>'` command from `skills/lark-sync/SKILL.md`.

2. **`.lark-sync.json` exists in the workspace root** — this is the runtime GUID map produced by `/lark-sync link` or `/lark-sync bootstrap`.

**Decision tree — do NOT ask before acting unless prerequisites are genuinely missing:**

1. **lark-cli not installed** → Ask user for permission to install it (`npm install -g @larksuite/cli`) and wait. No other path forward.
2. **lark-cli installed but config missing** (`lark-cli auth status` reports "not configured") → Ask the user for the Lark App ID and Secret (or point them to where the team shares these, per `skills/onboard/references/mcp-configs.md`). Wait for input, run `lark-cli config init`.
3. **Config present but no user token OR scopes incomplete** → Announce: "Re-authenticating Lark with required scopes." Run `lark-cli auth login --scope '<canonical list>'`. Present the browser URL. Wait for completion. Do NOT ask first — the need is unambiguous.
4. **Auth OK but `.lark-sync.json` missing** → Announce: "Linking workspace to the team's Lark tasklist and wiki. This is automatic and also backfills any existing local features." Then execute `/lark-sync link` (no args) directly. Do NOT ask; this is the expected first-run-after-update behavior for every user.
5. **Everything present** → Continue silently.

The only time the agent asks the user a question in this step is: (a) to install a missing dependency, (b) to collect credentials the agent cannot know, (c) to disambiguate when `/lark-sync link` finds multiple matching tasklists or wiki spaces.

**Migration semantics for existing users:** after an agentic-workflows update pulls this protocol into their workspace, the next session will reach Step 3.25, find `.lark-sync.json` missing, and auto-run `/lark-sync link`. That link command backfills every feature already in `.workflow-state.json` to Lark — tasks in the right sections, PRDs synced to wiki, per-user feature folders created. The user does nothing beyond authorizing the auth login in their browser when prompted. Do NOT gate this behind a confirmation question.

**Graceful degradation:** if `/lark-sync link` partially fails (e.g., tasklist found but wiki not), record what succeeded in `.lark-sync.json` and tell the user the remaining gap. Do NOT block the entire session — let them work with what's available.

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
