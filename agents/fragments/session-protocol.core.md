## SESSION START PROTOCOL (MANDATORY)

**This protocol MUST be executed before ANY other work. No exceptions.**

### Step 0: Detect workspace type

Check `.workflow-state.json` → `workspace_meta.is_jj_workspace`. If `true`, this is a secondary JJ workspace scoped to `workspace_meta.feature_slug`. Full JJ rules: `skills/jj-workflow/references/rules.md`.

### Step 0.5: Detect workspace state

1. **No service directories** (none of `api/`, `web/`, `ai-service/`, `data-service/` exist) → Fresh workspace. Use your ask tool: "This workspace hasn't been set up yet. Would you like to start onboarding now?" On yes, execute `skills/onboard/SKILL.md` directly. On no, tell the user they can run `/onboard` later.
2. **`.onboard-state.json` exists and `status` is `"in_progress"`** → Check `env_status`, `steps.db_setup`; if critical items missing, tell the user to run `/onboard resume` or `/onboard verify`. Block workflow commands until resolved.
3. **`.onboard-state.json` exists and `status` is `"completed"`** (or no `.onboard-state.json` but services exist) → Proceed. If `.workflow-state.json` missing, welcome the user and point at `/workflow start`, `/workflow list`.
4. **`.workflow-state.json` exists** → Proceed through remaining steps.

### Step 1: Check for instruction updates + sync

Run the update-check script and sync the current branch. Detailed procedure (including dependency bootstraps and conflict handling): `skills/workflow/references/session-checks.md` → "Update check + sync".

### Step 2: Load workflow state

Read `.workflow-state.json` to determine:
- Which feature is currently active (`active_feature`)
- What phase it's in (`features[active_feature].phase`)
- Who the current worker is (`worker`)

If `.workflow-state.json` doesn't exist, no features are active yet.

### Step 3: Verify Lark sync (MANDATORY)

If `.lark-sync.json` is missing or `lark-cli auth status` is incomplete, follow `skills/lark-sync/references/session-check.md` — re-auth silently when unambiguous, auto-run `/lark-sync link` when `.lark-sync.json` is missing. Ask only for missing credentials or installs.

### Step 4: Feature branch recency + service health

After pulling, if any service is on a `feature/*` or `wireframe/*` branch, run the recency check against its base branch. Then verify that required services are healthy. Full procedures (recency, re-run triggers, health commands): `skills/workflow/references/session-checks.md`.

### Step 5: Route to correct agent

Based on `.workflow-state.json`, delegate directly to the appropriate `frndos-*` agent for the current phase. Do NOT tell the user to manually invoke an agent — delegate.
