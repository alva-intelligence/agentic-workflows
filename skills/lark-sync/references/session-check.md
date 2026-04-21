## Session-time Lark sync verification

Lark sync is **required** for all frndOS workspaces — the team depends on shared visibility of feature state. At session start (or any time `/lark-sync` is invoked), confirm both parts are in place:

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

**Migration semantics for existing users:** after an agentic-workflows update pulls this protocol into their workspace, the next session will reach this check, find `.lark-sync.json` missing, and auto-run `/lark-sync link`. That link command backfills every feature already in `.workflow-state.json` to Lark — tasks in the right sections, PRDs synced to wiki, per-user feature folders created. The user does nothing beyond authorizing the auth login in their browser when prompted. Do NOT gate this behind a confirmation question.

**Graceful degradation:** if `/lark-sync link` partially fails (e.g., tasklist found but wiki not), record what succeeded in `.lark-sync.json` and tell the user the remaining gap. Do NOT block the entire session — let them work with what's available.
