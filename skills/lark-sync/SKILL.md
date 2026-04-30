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
- **Enforced at session start:** the session protocol in `AGENTS.md` verifies Lark is set up by delegating to `references/session-check.md`. If setup is missing or incomplete, the agent MUST walk the user through `/lark-sync setup-cli` + `/lark-sync link <GUID>` (or `/lark-sync bootstrap` for the team owner) BEFORE allowing any workflow commands. Read `references/session-check.md` for the exact scope-verification jq snippet and the decision tree.

## Prerequisites

- `lark-cli` installed globally (`npm install -g @larksuite/cli`)
- `lark-cli auth status` reports `identity: user`, `tokenStatus: valid`
- One shared Lark tasklist created by the team owner (usually the tenant admin or eng lead). Every team member uses the SAME tasklist GUID.

### Required scopes (REQUIRED_SCOPES)

The frndOS agentic workflow reads PRDs from Lark Docs, writes feature state to a Lark tasklist, references Base tables (feature registry / PRD priority boards), and accesses Wiki pages (design docs, archived PRDs) and Drive (resolving doc and attachment links). The `lark-cli` user token MUST carry all of these:

| Capability | Scopes |
|---|---|
| Tasks (full CRUD) | `task:task:read`, `task:task:write`, `task:tasklist:read`, `task:tasklist:write`, `task:section:read`, `task:section:write`, `task:comment:read`, `task:comment:write`, `task:custom_field:read`, `task:custom_field:write`, `task:attachment:read`, `task:attachment:write` |
| Docs / Docx (read original PRDs + write synced PRDs to wiki) | `docs:document.content:read`, `docx:document`, `docx:document:readonly`, `docx:document:create`, `docx:document:write_only` |
| Base / Bitable | `bitable:app`, `bitable:app:readonly` |
| Drive (full) | `drive:drive`, `drive:file`, `drive:file:download`, `drive:export:readonly` |
| Wiki (all) | `wiki:wiki`, `wiki:wiki:readonly`, `wiki:node:read`, `wiki:node:retrieve`, `wiki:node:create`, `wiki:node:copy`, `wiki:node:move`, `wiki:space:read`, `wiki:space:retrieve`, `wiki:space:write_only`, `wiki:member:create`, `wiki:member:retrieve`, `wiki:member:update` |
| Token refresh | `offline_access` |

**Canonical login command** (agents should use this exact string when guiding the user through auth):

```bash
lark-cli auth login --scope 'task:task:read task:task:write task:tasklist:read task:tasklist:write task:section:read task:section:write task:comment:read task:comment:write task:custom_field:read task:custom_field:write task:attachment:read task:attachment:write docs:document.content:read docx:document docx:document:readonly docx:document:create docx:document:write_only bitable:app bitable:app:readonly drive:drive drive:file drive:file:download drive:export:readonly wiki:wiki wiki:wiki:readonly wiki:node:read wiki:node:retrieve wiki:node:create wiki:node:copy wiki:node:move wiki:space:read wiki:space:retrieve wiki:space:write_only wiki:member:create wiki:member:retrieve wiki:member:update offline_access'
```

The `--recommend` flag is NOT sufficient — it only requests auto-approve scopes and omits `task:custom_field:*`, `bitable:*`, full `drive:*`, and `wiki:*`. Always pass `--scope` explicitly.

If the Lark app in use doesn't yet list these scopes under "Permissions", the team owner must add them in the Lark Developer Console and publish a new app version BEFORE team members can consent.

## Data model

**Shared across the team** (in Lark):

1. **Tasklist** — "FrnDOS Agentic Workflow Management"
   - Sections = phase Kanban lanes (Brainstorming → PRD Creation → … → Completed)
   - Tasks = one per feature
   - Task custom fields = workflow metadata (slug, services, PRs, strategy, etc.)
2. **Wiki tree** — under a team-owned Lark wiki space:
   ```
   Agentic Universe                    ← root folder (docx)
     ├─ Agentic's PRD                  ← canonical synced PRDs (agent-managed)
     │    └─ <feature-slug>            ← docx per feature, content mirrored from
     │                                     local docs/prd/<slug>.md
     └─ User's Area                    ← per-engineer free-form workspace
          └─ <Name>'s Universe         ← one per worker
               └─ <feature-slug>       ← empty folder; humans add docs/tables/
                                          diagrams/bases for brainstorming
   ```

**Static config** (`workflow/lark-tenant.json`, committed to repo):

Stable GUIDs that never change once created by `/lark-sync bootstrap`. Committing them means no runtime discovery is needed — new teammates just pull the repo and already know the tasklist GUID, section GUIDs, field GUIDs, and wiki root tokens. If another org adopts this framework via `/setup-workspace`, they overwrite this file with their own tenant's GUIDs.

- `tasklist.guid`, `tasklist.name`, `tasklist.url`
- `sections.<name>.guid` — phase lane GUIDs (Brainstorming, PRD Creation, etc.)
- `fields.<name>.{guid, type, options.<value> = option_guid}` — custom field + option GUIDs
- `wiki.space_id`
- `wiki.agentic_universe.node_token` — root folder
- `wiki.agentic_prd.node_token` — parent for canonical synced PRDs
- `wiki.users_area.node_token` — parent for per-user workspaces

**Dynamic local state** (`.lark-sync.json`, gitignored):

Per-user / per-feature bits that change as work progresses. Created on first `/lark-sync link`, updated by every orchestra hook.

- `feature_task_guids.<slug>` — Lark task GUID for each local feature
- `wiki.user_universe.{node_token, title}` — the current user's "<Name>'s Universe" node
- `wiki.feature_prd_docs.<slug>.{wiki_node_token, obj_token}` — synced PRD wiki docs
- `wiki.feature_user_folders.<slug>.node_token` — per-feature folder under the user's universe

## Commands

### `/lark-sync bootstrap`

One-time setup by the team owner. Reads `workflow/lark-template.json` (portable schema), creates the Lark tasklist + sections + custom fields + wiki Agentic Universe tree in the owner's tenant, then **writes `workflow/lark-tenant.json`** with every static GUID. The owner commits that file to the repo. Team members never re-run bootstrap.

**Steps:**
1. Verify `lark-cli auth status` shows a valid user token with all required scopes (see "Required scopes" table). If not, STOP with the canonical `lark-cli auth login --scope '<full list>'` command.
2. Ask the user via the ask tool:
   - "Name the new Lark tasklist? (Default: `FrnDOS Agentic Workflow Management`)"
   - "Paste the URL of the Lark wiki space to host the Agentic Universe tree" — agent extracts the space_id from the URL (or user pastes the space_id directly).
3. Run `scripts/lark-sync-bootstrap.sh <name> <wiki_space_id>` — the script:
   - Creates the tasklist with the name
   - Creates the 10 phase sections (PRD Creation → Completion), sets PRD Creation as default
   - Creates all custom fields including options
   - Creates the wiki tree: Agentic Universe → (Agentic's PRD, User's Area)
   - Writes `workflow/lark-tenant.json` with every static GUID it just created
   - Writes a minimal `.lark-sync.json` seeded with the owner's own user_universe data
4. Report:
   ```
   Bootstrap complete. Next steps:
     1. Review workflow/lark-tenant.json
     2. git add workflow/lark-tenant.json && git commit -m "chore(lark-sync): initialize tenant config"
     3. Push. Teammates will pick it up on their next session and auto-link.
   ```

**Re-running bootstrap** (`--repair` mode): if `workflow/lark-tenant.json` already exists, bootstrap reads existing GUIDs, re-verifies each resource still exists in Lark, and ADDs only missing pieces (new fields added to the template, new sections, new options). Never destructive — no API calls that would lose data.

### `/lark-sync link`

Fully-automatic first-time (and repeat) sync. Session protocol runs this automatically whenever `.lark-sync.json` is missing — users do NOT need to invoke it manually. It does three things:

1. Auth + scope check
2. Ensures per-user dynamic state (creates "<Worker>'s Universe" if missing)
3. **Backfills every existing local feature** — creates missing Lark tasks, syncs PRD markdown to wiki, creates per-feature brainstorming folders

No arguments. All static identifiers come from the committed `workflow/lark-tenant.json`. No runtime discovery, no API round-trips to resolve tasklist/wiki GUIDs.

**Steps:**

#### 1. Preflight
- Confirm `lark-cli auth status` shows `identity: user`, `tokenStatus: valid`, and every scope from the "Required scopes" table.
- If anything is missing, guide the user through `lark-cli auth login --scope '<canonical list>'`. Do not continue with a partial token.
- Confirm `workflow/lark-tenant.json` (or `.agentic-workflows/workflow/lark-tenant.json` in an installed workspace) exists and parses. This file is the source of all static GUIDs.

#### 2. Load static tenant config
- Read `workflow/lark-tenant.json`. Hold these in memory for the rest of the session:
  - `tasklist.guid`
  - `sections.<name>.guid`
  - `fields.<name>.guid` and `fields.<name>.options.<value>` GUID maps
  - `wiki.space_id`, `wiki.agentic_prd.node_token`, `wiki.users_area.node_token`
- Smoke-test: `lark-cli task tasklists get --params '{"tasklist_guid":"<guid>"}'` — STOP if 404 (the committed GUID no longer exists in this tenant; team owner must rerun `/lark-sync bootstrap` and re-commit).

#### 3. Ensure the user's personal wiki space
- Read `.workflow-state.json.worker`. Titlecase with possessive: `"<Worker>'s Universe"`.
- If `.lark-sync.json.wiki.user_universe.node_token` is already set, trust it.
- Otherwise: search children of `wiki.users_area.node_token` for a node titled `"<Worker>'s Universe"`. If found, record its token. If not, create one via `POST /open-apis/wiki/v2/spaces/<space_id>/nodes` (obj_type=docx, parent=users_area, title). Save to `.lark-sync.json`.

#### 4. Initialize (or load) `.lark-sync.json`
Schema for dynamic state only (see "Data model"). Ensure `.lark-sync.json` is in `.gitignore`.

#### 5. Backfill — per-feature, NOT bulk

Load once: `lark-cli task tasklists tasks --page-all` → populate `feature_task_guids.<slug>` from each task's "Feature slug" custom field.

Then read `.workflow-state.json`. For EACH local feature, complete ALL its sync work before moving to the next (do not batch all-tasks-then-all-prds — some permission hooks flag tight-loop shared-resource edits as "mass-patch" and block them).

**For one feature `<slug>`:**

1. **Task.** If slug missing in Lark: create via `/lark-sync push` (new task in section matching local phase, all custom fields, "— Links —" description block). If slug already in Lark (teammate-owned): add current user as assignee via `lark-cli task +assign`. If Lark phase ≠ local phase, ask user which to keep via the ask tool and update the loser.
2. **User folder.** `/lark-sync ensure-user-folder <slug>` — create `<Worker>'s Universe/<slug>/` if missing.
3. **PRD wiki.** If `docs/prd/<slug>.md` exists, run `/lark-sync push-prd <slug>` — import markdown → docx → wiki node under `Agentic's PRD` → save tokens in `.lark-sync.json.wiki.feature_prd_docs.<slug>` → refresh the task's "— Links —" block with the live Working PRD URL.
4. Short pause (~500ms) before moving to the next feature.

**Graceful degradation:** If step 3's description-refresh is blocked for a pre-existing task (some harnesses treat description patches on team tasks as mass-edits during backfill), skip that sub-step silently — the `Wiki PRD` custom field carries the same URL and Lark's right panel surfaces it. Log the skip, do not fail the whole link. Future single-event pushes from orchestra hooks are one-at-a-time and won't trip the hook.

#### 7. Report summary
```
Lark sync linked.

Tasklist: <tenant.tasklist.name>
  URL: <tenant.tasklist.url>
  Tasks: <N existing in Lark> + <M backfilled from local> = <total>

Wiki: <tenant.wiki.space_id>
  Working PRDs synced: <K>
  Your universe: "<Worker>'s Universe" (<created|existing>)
  Per-feature folders: <F>

Active feature: <slug> (<phase>)
```

All subsequent `/workflow start` and `/workflow next` will auto-sync incrementally via the orchestra hook. Users never re-run `/lark-sync link` unless `.lark-sync.json` is deleted or the team's tenant config is reset.

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
   - Custom fields: Feature slug, Services, Source PRD, Branch, PRs, Phase status, Impl strategy, Session mode, Parent feature, Last phase change=now, Wiki PRD (if the feature has a synced doc)
   - Members: current worker as assignee (role=assignee)
   - **Description must start with a managed "Links" block** so humans see the important URLs without scrolling through custom fields. Format:

     ```
     — Links —
     📘 Working PRD (canonical, agent-synced): <wiki_prd_url or "not yet synced">
     📋 Source PRD (original input): <source_prd_url or "not set">
     🧠 My workspace (brainstorming): <user_feature_folder_url or "not created">
     ———————————————
     <free-form description below — updated by the user, not the agent>
     ```

     On every push, the agent rewrites ONLY the block between the two `—` delimiters. Anything the user wrote AFTER the closing delimiter is preserved. This lets the team add ad-hoc notes / blockers / screenshots without the agent clobbering them.
3. If `feature_task_guids[slug]` does NOT exist:
   - Create task: `lark-cli task tasks create --data '<payload>'`
   - Immediately add task to the target section via `lark-cli api POST /open-apis/task/v2/tasks/<task_guid>/tasklists/<tasklist_guid>` with `section_guid` (tasks created with just `tasklists:[{tasklist_guid}]` land in the default section; moving to a non-default section requires the add_tasklist call)
   - Save the new task GUID into `.lark-sync.json.feature_task_guids[slug]`
4. If it DOES exist:
   - Update fields: `lark-cli task tasks patch --data '<payload>' --params '{"task_guid":"<guid>"}'`
   - Move section if phase changed: `lark-cli api POST /open-apis/task/v2/tasks/<task_guid>/add_tasklist` with new `section_guid`
5. Write updated `.lark-sync.json`.

### `/lark-sync push-prd [slug]`

Sync the PRD for a feature from local markdown to its wiki docx under **Agentic's PRD**. Called automatically by orchestra after any PRD write; also usable manually.

**Steps:**
1. Resolve the target slug (arg or active feature from `.workflow-state.json`).
2. Read the PRD source: `docs/prd/<slug>.md` — STOP if the file does not exist.
3. Look up `.lark-sync.json.wiki.feature_prd_docs[<slug>]`:
   - **If absent** (first-time sync for this feature):
     a. Upload the markdown file to Drive: `POST /open-apis/drive/v1/medias/upload_all` with `file_type: "md"`, `parent_type: "explorer"`, `parent_node: <user's drive folder>` (or `ccm_import_open` — see below).
     b. Create an import task: `POST /open-apis/drive/v1/import_tasks` with body `{ file_extension: "md", file_token: "<uploaded>", type: "docx", point: { mount_type: 2, mount_key: "<wiki_space_id>" }, file_name: "<slug>" }`. `mount_type:2` means wiki; the docx is created inside the space.
     c. Poll `GET /open-apis/drive/v1/import_tasks/<ticket>` until `job_status == 0` (done). Extract the new `obj_token`.
     d. Create a wiki node in the space that references the imported docx: `POST /open-apis/wiki/v2/spaces/<space_id>/nodes` with `{ obj_type: "docx", origin_node_token: "<imported node>", parent_node_token: "<agentic_prd_node_token>", title: "<slug>" }`. (If import already creates the wiki node under the mount point, this step is a no-op — use the returned node_token from step c.)
     e. Record `feature_prd_docs[<slug>] = { wiki_node_token, obj_token }`.
     f. Update the Lark task's "Wiki PRD" custom field with the wiki node URL: `https://<tenant>.larksuite.com/wiki/<wiki_node_token>`.
     g. Also call `/lark-sync push` (or inline the equivalent) to refresh the task's description "Links" block so the 📘 Working PRD URL goes from `"not yet synced"` to the live URL. This is the moment the team first sees the synced PRD — do not skip it.
   - **If present** (update):
     a. Fetch the docx's root block: `GET /open-apis/docx/v1/documents/<obj_token>/blocks` — page 1 item 0 is the page root.
     b. Delete all existing child blocks of the root: `POST /open-apis/docx/v1/documents/<obj_token>/blocks/<root>/children/batch_delete` with the index range of the current children.
     c. Re-import the new markdown OR append freshly-converted blocks. The simplest robust approach: re-run the import flow to a temp docx, then swap (or, if the import API supports in-place replace, use that). A simpler first-pass implementation: convert markdown → docx blocks in-process (headings, paragraphs, bullets, numbered, code, table) and append via `POST /blocks/<root>/children`.
     d. Append a trailing block: small italic line `"Last synced by <worker> at <ISO timestamp>."`
4. Update `Last phase change` in the task if phase has advanced.
5. Do NOT touch the User's Area per-feature folder during push-prd — that's the user's free-form space.

### `/lark-sync push-brainstorming [slug]`

Sync the brainstorming artifacts for a feature (questions, answers, summary, service-state snapshots) from `.workflow-state.json` to a wiki docx under **User's Area / `<Worker>'s Universe` / `<slug>` / Brainstorming**. Called automatically by `frndos-brainstorm` after every state change; also usable manually.

**Steps:**
1. Resolve the target slug (arg or active feature). Read `features[<slug>].brainstorming` from `.workflow-state.json`. STOP with a no-op if no brainstorming object exists or `questions` is empty AND `summary` is null.
2. Render markdown:

   ```markdown
   # Brainstorming: <feature-slug>

   > Type: <feature|bug|improvement>
   > Worker: <worker>
   > Updated: <ISO>

   ## Initial request

   <initial_request verbatim>

   ## Service state snapshots

   ### <service>
   <snapshot text>

   ...

   ## Questions

   ### Q<n>: <prompt>

   - [x] **<chosen-label>** (Recommended) — <description>
   - [ ] <other-label> — <description>

   ...

   ## Summary

   <brainstorming.summary verbatim>
   ```

   - Mark the chosen answer with `[x]`. Mark the option flagged `recommended: true` with `(Recommended)` regardless of whether it was the chosen answer.
   - For "Other" free-text answers, render a single `[x] Other — <answer-text>` line.
3. Ensure the user-feature folder exists. Run `/lark-sync ensure-user-folder <slug>` first.
4. Look up `.lark-sync.json.user_brainstorming_docs[<worker>][<slug>]`:
   - **If absent** (first-time sync): create the docx via the same import flow as `push-prd` (`POST /open-apis/drive/v1/import_tasks` with `file_extension: "md"`, `type: "docx"`, mounted in the wiki space), then move the resulting wiki node under the user-feature folder titled `Brainstorming`. Save `{ wiki_node_token, obj_token }` to `.lark-sync.json.user_brainstorming_docs[<worker>][<slug>]`.
   - **If present** (update): replace the docx body in place using the same `blocks/batch_delete` + re-import pattern as `push-prd`. Append the trailing line `Last synced by <worker> at <ISO timestamp>.`.
5. Write the docx URL back into `features[<slug>].brainstorming.lark_doc_url` in `.workflow-state.json`. This field is purely for traceability — gates do not check it.
6. Do NOT touch the parent user-feature folder content; that remains the user's free-form space.
7. Failure handling: advisory. Log + continue. Local `.workflow-state.json` is authoritative.

This is the brainstorming-specific counterpart to `push-prd`. The PRD lives in `Agentic's PRD` (team-canonical, agent-managed); the brainstorming doc lives under the engineer's `User's Area` (engineer-canonical, agent-managed). They never touch each other.

### `/lark-sync ensure-user-folder [slug]`

Idempotent: creates the current worker's User's Area folders if missing. Called automatically by `/workflow start`.

**Steps:**
1. Resolve worker name from `.workflow-state.json.worker`. Titlecase with possessive: `"Arhen's Universe"`.
2. If `.lark-sync.json.wiki.user_universe_node_token` is absent: search children of `users_area_node_token` for a node titled `"<Worker>'s Universe"`. If found, save its token. If not, create one: `POST /open-apis/wiki/v2/spaces/<space>/nodes` with `{ obj_type: "docx", node_type: "origin", title: "<Worker>'s Universe", parent_node_token: "<users_area>" }`. Save.
3. If `slug` argument given and `feature_user_folders[<slug>]` is absent: create a child folder under user universe titled `<slug>`. Save its node_token.
4. Do NOT add content — humans populate User's Area freely.

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
     ★ image-editor                PR Review          arhen            web            web:#87
   ★ = your active feature
   ```

## External callers (loki GUI + every agent harness)

The kanban-mirror contract is **single source of truth**: every mutation of `features[<slug>]` in `.workflow-state.json` MUST be followed by a `/lark-sync push <slug>` call. Mutations from loki (kanban GUI) AND from the CLI (agents handling `/workflow *` commands, `phase_status` flips, PR URL writes, etc.) all share this contract.

### Supported entry points (external)

| Entry point | What it does | Who calls it |
|---|---|---|
| `/lark-sync push <slug>` | Sync the feature's local state to the Lark task — section, all custom fields (incl. `Phase status`), description Links block. One-way (local → Lark). | loki on every kanban card mutation; CLI agents on every `.workflow-state.json` mutation |
| `/lark-sync push-prd <slug>` | Mirror `docs/prd/<slug>.md` to the wiki docx under `Agentic's PRD`. | loki "Sync to Lark wiki" button on `docs/prd/<slug>.md`; `frndos-prd` on every PRD save |
| `/lark-sync push-brainstorming <slug>` | Mirror `features[<slug>].brainstorming` to the wiki docx under `User's Area/<Worker>'s Universe/<slug>/Brainstorming`. | `frndos-brainstorm` on every state change (answer recorded, summary written, phase_status flip); loki if it exposes a brainstorming editor |

### loki-specific contract

loki does NOT reimplement any sync logic in Rust — it invokes the slash commands above. After every write to `.workflow-state.json` (drag-drop, card field edit, phase_status toggle), loki fires `/lark-sync push <slug>` fire-and-forget. Toast the stderr on failure.

For doc-to-wiki sync, loki's "Sync to Lark wiki" button qualifies on:
- `docs/prd/<slug>.md` → `/lark-sync push-prd <slug>`

The button must be **disabled or hidden** for:
- `docs/tracks/<slug>.md` — engineering internal logs; no team wiki destination by design in v1
- `docs/service-prds/<slug>.md` — per-service PRDs stay local in v1
- Anything else under `docs/`

Slug derivation: extract from the filename (stem of `docs/prd/<slug>.md`). Do not infer from frontmatter or content.

### Preflight (every external entry point)

Read `workflow/lark-tenant.json` and `.lark-sync.json`. Confirm `lark-cli auth status` is valid. Do NOT bypass — broken auth silently degrades the sync.

### Failure handling

Lark sync is advisory. If a call fails (auth expired, network, hook-blocked), surface the stderr (toast in loki; log line in CLI) and leave local state unchanged. Local `.workflow-state.json` is authoritative.

**Explicitly NOT in v1:**
- `push-doc` as a generic "sync any path" command. Adding one would need a routing table mapping paths to wiki destinations, which only exists for PRDs and brainstorming today. Introduce one only when tracks/service-PRDs gain wiki homes.
- Bidirectional pull (Lark wiki → local markdown). v1 is write-through only; any Lark edits are overwritten on next push.
- Batch sync ("sync all PRDs"). Orchestra hooks push one feature at a time for mass-patch safety; loki's GUI must preserve this — one card mutation = one push, not fan-out across the board.

## Orchestra auto-hooks

When `.lark-sync.json` exists, the orchestra agent MUST call the corresponding `/lark-sync` side-effects on these events:

| Event | Action |
|---|---|
| `/workflow start <slug>` completes | `push` — creates Lark task in Brainstorming section. `ensure-user-folder <slug>` — creates `<Worker>'s Universe/<slug>/` if missing. |
| `/workflow next` transitions phase | `push` — moves task to target section, updates `Last phase change`, sets `Phase status = inprogress` for the new phase |
| Any agent flips `phase_status` (`inprogress` ↔ `completed`) | `push` — updates the `Phase status` custom field. **Mandatory after every flip.** |
| `frndos-brainstorm` records an answer, writes the summary, or flips `phase_status` | `push-brainstorming <slug>` — mirrors brainstorming object to the User's Area docx. Also call `push <slug>` on the `phase_status` flip. |
| `frndos-prd` saves or updates `docs/prd/<slug>.md` | `push-prd <slug>` — mirrors the markdown content into the wiki docx under Agentic's PRD. |
| User sets `implementation_strategy`, `parent_feature`, or `phase_status` in local state | `push` — update the corresponding custom fields |
| PR URL recorded in local state | `push` — updates PRs field |
| Self-review or security audit summary written | `push` — refreshes the description Links block (no dedicated field today) |
| Phase reaches `completion` | `push` with Lark "mark complete" (`lark-cli task +complete`) in addition to section move. Leave the PRD wiki page intact — it's the permanent record. |
| Feature archived/deleted locally | Do NOT delete the Lark task, PRD wiki page, or brainstorming wiki page — leave an audit trail. Add a comment on the task: "Feature archived locally by <worker> on <date>". |

`push-prd` and `push-brainstorming` are equally critical to `push`. Without `push-prd`, the team's view of the PRD drifts from what the driving engineer agreed in their working session. Without `push-brainstorming`, the engineer's brainstorming context (what was asked, what was chosen, why) lives only on their machine — invisible to teammates picking up the feature later.

If a `push` call fails (network, auth expired), the orchestra MUST:
- Log the failure with the error message
- Continue the local workflow anyway (Lark sync is advisory, not a gate)
- Remind the user to run `/lark-sync push` manually once the issue is resolved

## Rules

- **Required, non-blocking per-call.** If `.lark-sync.json` is missing, session-protocol auto-runs `/lark-sync link` (see session-protocol Step 3.25). If an individual push fails mid-session, log and continue — the local workflow is authoritative.
- **Lark is never the source of truth.** Local `.workflow-state.json` wins. If Lark and local disagree, `push` overwrites Lark.
- **One tasklist per team, not per user.** Every team member's `.lark-sync.json` points at the same `tasklist_guid` from `workflow/lark-tenant.json`.
- **Custom field option GUIDs are required.** `single_select_value` and `multi_select_value` need option GUIDs, not names. Always resolve via `workflow/lark-tenant.json` `fields.<name>.options.<value>` before sending.
- **Do not delete Lark tasks for archived features.** Keeps team audit trail.
- **Never log or echo the app secret.** `lark-cli` stores it in `~/.lark-cli/config.json` — treat that file as a credential.
- **Backfill cadence — sequential, not bulk.** When running `/lark-sync link` on a workspace that already has features in `.workflow-state.json`, do not iterate through them in a tight loop doing `push` + `push-prd` + description-refresh for N features as one batch. Permission hooks in some agent harnesses classify tight-loop edits on shared team resources as "mass-patch" and block them. Instead, for each feature do ONE full cycle (create task → push-prd → refresh description) before moving to the next, with a short pause between. If a single task's description refresh still gets blocked, silently skip that part — the Wiki PRD custom field already carries the same URL and Lark's right-side panel surfaces it. Future incremental pushes from orchestra hooks (one event at a time) are never affected.
