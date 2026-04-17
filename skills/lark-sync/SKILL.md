---
name: lark-sync
description: Sync feature workflow state to a shared Lark tasklist so the team can see who is working on what and which phase each feature is in. REQUIRED for all frndOS workspaces.
---

# Lark Sync

Syncs workflow features to a shared Lark tasklist. Each feature = one Lark task; phase = Kanban section. Gives the team a single, always-live view of every active feature.

**This skill is REQUIRED, not optional.** The frndOS workflow depends on team-wide visibility of feature state. A workspace without Lark sync configured is not usable for team work — `/workflow start` and `/workflow next` will BLOCK until `.lark-sync.json` exists and the lark-cli is authenticated.

## When this runs

- **Manual commands:** `/lark-sync bootstrap`, `/lark-sync link`, `/lark-sync status`, `/lark-sync push`, `/lark-sync pull`, `/lark-sync setup-cli`
- **Automatic:** orchestra calls `/lark-sync push` on every phase transition in `/workflow start`, `/workflow next`, and completion.
- **Enforced at session start:** session-protocol Step 4 verifies Lark is set up. If not, the agent MUST walk the user through `/lark-sync setup-cli` + `/lark-sync link <GUID>` (or `/lark-sync bootstrap` for the team owner) BEFORE allowing any workflow commands.

## Prerequisites

- `lark-cli` installed globally (`npm install -g @larksuite/cli`)
- `lark-cli auth status` reports `identity: user`, `tokenStatus: valid`
- One shared Lark tasklist created by the team owner (usually the tenant admin or eng lead). Every team member uses the SAME tasklist GUID.

### Required scopes (REQUIRED_SCOPES)

The frndOS agentic workflow reads PRDs from Lark Docs, writes feature state to a Lark tasklist, references Base tables (feature registry / PRD priority boards), and accesses Wiki pages (design docs, archived PRDs) and Drive (resolving doc and attachment links). The `lark-cli` user token MUST carry all of these:

| Capability | Scopes |
|---|---|
| Tasks (full CRUD) | `task:task:read`, `task:task:write`, `task:tasklist:read`, `task:tasklist:write`, `task:section:read`, `task:section:write`, `task:comment:read`, `task:comment:write`, `task:custom_field:read`, `task:custom_field:write`, `task:attachment:read`, `task:attachment:write` |
| Docs / Docx (read PRDs) | `docs:document.content:read`, `docx:document:readonly` |
| Base / Bitable | `bitable:app`, `bitable:app:readonly` |
| Drive (full) | `drive:drive`, `drive:file`, `drive:file:download`, `drive:export:readonly` |
| Wiki (all) | `wiki:wiki`, `wiki:wiki:readonly`, `wiki:node:read`, `wiki:node:retrieve`, `wiki:node:create`, `wiki:node:copy`, `wiki:node:move`, `wiki:space:read`, `wiki:space:retrieve`, `wiki:space:write_only`, `wiki:member:create`, `wiki:member:retrieve`, `wiki:member:update` |
| Token refresh | `offline_access` |

**Canonical login command** (agents should use this exact string when guiding the user through auth):

```bash
lark-cli auth login --scope 'task:task:read task:task:write task:tasklist:read task:tasklist:write task:section:read task:section:write task:comment:read task:comment:write task:custom_field:read task:custom_field:write task:attachment:read task:attachment:write docs:document.content:read docx:document:readonly bitable:app bitable:app:readonly drive:drive drive:file drive:file:download drive:export:readonly wiki:wiki wiki:wiki:readonly wiki:node:read wiki:node:retrieve wiki:node:create wiki:node:copy wiki:node:move wiki:space:read wiki:space:retrieve wiki:space:write_only wiki:member:create wiki:member:retrieve wiki:member:update offline_access'
```

The `--recommend` flag is NOT sufficient — it only requests auto-approve scopes and omits `task:custom_field:*`, `bitable:*`, full `drive:*`, and `wiki:*`. Always pass `--scope` explicitly.

If the Lark app in use doesn't yet list these scopes under "Permissions", the team owner must add them in the Lark Developer Console and publish a new app version BEFORE team members can consent.

## Data model

**Shared across the team** (in Lark):
- Tasklist: one per team, e.g. "FrnDOS Agentic Workflow Management"
- Sections = phase Kanban lanes (PRD Creation → Wireframe → … → Completion)
- Tasks = one per feature
- Task custom fields = workflow metadata (slug, services, PRs, strategy, etc.)

**Local per-workspace** (`.lark-sync.json`, gitignored):
- `tasklist_guid` — the shared tasklist
- `sections.<name>.guid` — section GUIDs for phase lookup
- `fields.<name>.guid` — custom field GUIDs
- `fields.<name>.options.<value>.guid` — option GUIDs for single/multi select fields
- `feature_task_guids` — map of local feature slug → Lark task GUID (so updates find the right task)

## Commands

### `/lark-sync bootstrap`

One-time setup by the team owner. Reads `workflow/lark-template.json` and creates a new Lark tasklist with the required sections and custom fields. Team members use `/lark-sync link` afterward instead of running bootstrap again.

**Steps:**
1. Verify `lark-cli auth status` shows a valid user token with all required scopes. If not, STOP with: "Run `lark-cli auth login --scope 'task:task:read task:task:write task:tasklist:read task:tasklist:write task:section:read task:section:write task:custom_field:read task:custom_field:write offline_access'`"
2. Ask the user via the ask tool: "Name the new Lark tasklist? (Default: `FrnDOS Agentic Workflow Management`)"
3. Run `scripts/lark-sync-bootstrap.sh <name>` — script creates tasklist, sections, and custom fields in order. On success it emits the new tasklist GUID.
4. Write `.lark-sync.json` in the workspace root (runtime config with all GUIDs). Add `.lark-sync.json` to `.gitignore` if not already there.
5. Report: "Tasklist created. GUID: `<guid>`. Share this GUID with teammates — they run `/lark-sync link <guid>` to connect their workspace."

### `/lark-sync link [tasklist_guid]`

Team members run this once to point their workspace at the team's existing tasklist. Also performs a **first-time backfill** — any local features already in `.workflow-state.json` that do NOT yet have a Lark task get pushed up so the whole team immediately sees them.

**The `tasklist_guid` argument is optional.** If omitted, the skill searches for the tasklist by name — no team-lead handoff needed for new members.

**Steps:**
1. Verify `lark-cli auth status` (same as bootstrap).
2. **Resolve the tasklist GUID:**
   - If the user passed `<tasklist_guid>` explicitly: use it directly. Skip to step 3.
   - Otherwise, auto-discover by name:
     ```bash
     NAME=$(jq -r '.tasklist_name' workflow/lark-template.json)   # or .agentic-workflows/workflow/lark-template.json
     lark-cli task +tasklist-search --query "$NAME" --page-all
     ```
     - **Exactly one match** → use its GUID. Report to user: "Found `<NAME>` (GUID `<guid>`) — linking."
     - **Multiple matches** → use the ask tool (Claude Code: `AskUserQuestion`) to let the user pick. List each candidate's GUID, owner name, and created date.
     - **Zero matches** → STOP with: "No tasklist named `<NAME>` is visible to your Lark user. Either the team owner has not run `/lark-sync bootstrap` yet, or your Lark account does not have access to it. Ask the team lead to share the tasklist with you, then retry."
3. Fetch the tasklist metadata — STOP if GUID is invalid or user lacks access.
3. Fetch all sections and custom fields via `lark-cli api GET`. Build the name → GUID mapping.
4. Validate the structure matches `workflow/lark-template.json`:
   - All required sections present (names match `sections.ordered[].name`)
   - All required custom fields present (names + types match)
   - If missing: WARN listing what's missing and suggest the team owner re-run `/lark-sync bootstrap` or manually add.
5. Write `.lark-sync.json` with tasklist_guid + mappings. Initialize `feature_task_guids` to `{}`.
6. Fetch current tasks via `lark-cli task tasklists tasks --page-all`. For each task, fetch its "Feature slug" custom field value and populate `feature_task_guids[<slug>] = <task_guid>`.
7. **Backfill local features → Lark** (first-time sync for existing workspaces):
   - Read `.workflow-state.json`.
   - For each feature in `features{}`:
     - If the slug already exists in `feature_task_guids` (someone else on the team created it): add the current user as an assignee to that Lark task (don't duplicate). Warn if the Lark task's phase doesn't match local phase — ask the user via the ask tool which is correct, and update whichever side they choose.
     - If the slug is NOT in Lark: run `/lark-sync push` for that feature to create a new task in the correct section with all its custom fields populated.
   - Emit a summary: "Backfill complete: created `<N>` new tasks, joined `<M>` existing tasks, resolved `<K>` phase conflicts."
8. Report: "Linked to `<tasklist_name>`. Found `<N>` existing team feature tasks. Backfilled `<M>` local features."

### `/lark-sync status`

Show the Lark task for the currently active feature (from `.workflow-state.json`).

**Steps:**
1. Read `.workflow-state.json` — get `active_feature` slug.
2. Read `.lark-sync.json` — look up `feature_task_guids[active_feature]`.
3. If no task GUID: "No Lark task for `<slug>`. Run `/lark-sync push` to create one."
4. Otherwise: `lark-cli task tasks get --params '{"task_guid":"<guid>"}'` and display: title, current section (phase), assignees, Services, Branch, PRs, Impl strategy, link to Lark UI.

### `/lark-sync push`

Push the active feature's local state to Lark. Called automatically by orchestra; also usable manually.

**Steps:**
1. Read `.workflow-state.json` and `.lark-sync.json`.
2. Build the task payload from the active feature's local state:
   - Title: `<slug> — <summary>` (summary from PRD front matter if available, else slug)
   - Section: map current phase_key → section GUID via `.lark-sync.json.sections`
   - Custom fields: Feature slug, Services, Source PRD, Branch, PRs, Wireframe PR, Wireframe skipped, Impl strategy, Session mode, Parent feature, Last phase change=now
   - Members: current worker as assignee (role=assignee)
3. If `feature_task_guids[slug]` does NOT exist:
   - Create task: `lark-cli task tasks create --data '<payload>'`
   - Immediately add task to the target section via `lark-cli api POST /open-apis/task/v2/tasks/<task_guid>/tasklists/<tasklist_guid>` with `section_guid` (tasks created with just `tasklists:[{tasklist_guid}]` land in the default section; moving to a non-default section requires the add_tasklist call)
   - Save the new task GUID into `.lark-sync.json.feature_task_guids[slug]`
4. If it DOES exist:
   - Update fields: `lark-cli task tasks patch --data '<payload>' --params '{"task_guid":"<guid>"}'`
   - Move section if phase changed: `lark-cli api POST /open-apis/task/v2/tasks/<task_guid>/add_tasklist` with new `section_guid`
5. Write updated `.lark-sync.json`.

### `/lark-sync pull`

Fetch team-wide state from Lark and show it. Does NOT write to local `.workflow-state.json` — this is read-only team visibility.

**Steps:**
1. Read `.lark-sync.json`.
2. Fetch tasks: `lark-cli task tasklists tasks --params '{"tasklist_guid":"<guid>"}' --page-all`.
3. For each task, fetch detail + resolve custom field option GUIDs to names.
4. Display a compact table:
   ```
   Team activity in <tasklist_name>:

     Slug                          Phase              Assignees        Services       PRs
     ───────────────────────────── ────────────────── ──────────────── ────────────── ──────────
     brand-health-dashboard        Implementation     arhen, daffa     api, web       api:#201 web:#88
     user-analytics                PRD Creation       daffa            (none set)     —
     ★ image-editor                Wireframe Review   arhen            web            web:#87
   ★ = your active feature
   ```

## Orchestra auto-hooks

When `.lark-sync.json` exists, the orchestra agent MUST call the corresponding `/lark-sync push` side-effect on these events:

| Event | Action |
|---|---|
| `/workflow start <slug>` completes (feature row added to local state) | `push` — creates Lark task in PRD Creation section |
| `/workflow next` transitions phase | `push` — moves task to target section, updates `Last phase change` |
| User sets wireframe_skipped, impl_strategy, parent_feature in local state | `push` — update the corresponding custom fields |
| PR URL recorded in local state | `push` — updates PRs / Wireframe PR field |
| Phase reaches `completion` | `push` with Lark "mark complete" (`lark-cli task +complete`) in addition to section move |
| Feature archived/deleted locally | Do NOT delete the Lark task — leave an audit trail. Add a comment: "Feature archived locally by <worker> on <date>". |

If a `push` call fails (network, auth expired), the orchestra MUST:
- Log the failure with the error message
- Continue the local workflow anyway (Lark sync is advisory, not a gate)
- Remind the user to run `/lark-sync push` manually once the issue is resolved

## Rules

- **Opt-in, non-blocking.** If `.lark-sync.json` does not exist, this skill is inert and the workflow works exactly as it did before. Never force Lark setup on a user.
- **Lark is never the source of truth.** Local `.workflow-state.json` wins. If Lark and local disagree, `push` overwrites Lark.
- **One tasklist per team, not per user.** Every team member's `.lark-sync.json` points at the same `tasklist_guid`.
- **Custom field option GUIDs are required.** `single_select_value` and `multi_select_value` need option GUIDs, not names. Always resolve via `.lark-sync.json.fields.<name>.options.<value>.guid` before sending.
- **Do not delete Lark tasks for archived features.** Keeps team audit trail.
- **Never log or echo the app secret.** `lark-cli` stores it in `~/.lark-cli/config.json` — treat that file as a credential.
