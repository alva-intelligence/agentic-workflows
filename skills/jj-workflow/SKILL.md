---
name: jj-workflow
description: JJ (Jujutsu) workspace management — create isolated working directories for parallel feature development using JJ colocated mode. Separate from /workflow.
---

# JJ Workspace Manager

Manages JJ (Jujutsu) workspaces for parallel feature development. Each workspace is an isolated working directory where a separate terminal-based agent session (Claude Code or Amp) can work on a different feature independently.

**Key principles:**
- JJ runs in **colocated mode** — all git commands stay unchanged. JJ is ONLY used for workspace management.
- The frndOS workspace is NOT a single repo. It contains 4 service repos (`api/`, `web/`, `ai-service/`, `data-service/`). JJ operations are applied **per-service-repo**, orchestrated at the top level.
- This skill is **completely separate** from `/workflow`. The workflow skill handles the feature state machine; `/jj-workflow` handles workspace isolation.
- Most useful with **terminal-based harnesses** (Claude Code, Amp) where you run one session per directory. Cursor is IDE-integrated so benefits less; OpenCode also works per-session and can use workspaces if desired.

Full behavioral rules (independence, commit propagation, port conflicts, hierarchy, lifecycle, secondary-workspace detection) live in `references/rules.md`. Read it before creating, switching, or cleaning up workspaces.

## Korlap coexistence (Step 0 of every subcommand)

If the file `.korlap/marker.json` exists at the workspace root, **korlap (the GUI app) is managing isolation for this workspace**. In that case, every `/jj-workflow` subcommand (`init`, `new`, `list`, `status`, `cleanup`) MUST exit early without performing any action and print:

```
korlap is managing isolation in this workspace.
  → Add/list/remove feature workspaces from the korlap GUI instead.
  → `/jj-workflow` is disabled here to avoid two competing parallel-workspace models.

Marker: .korlap/marker.json (korlap version <read version field>)

If you want to use JJ workspaces instead, uninstall korlap from this workspace
(remove .korlap/) and re-run onboarding in terminal mode.
```

**Detection snippet** — run this at the start of every subcommand below, before any other step:

```bash
if [ -f .korlap/marker.json ]; then
  version=$(jq -r '.version // "unknown"' .korlap/marker.json 2>/dev/null || echo "unknown")
  echo "korlap is managing isolation in this workspace."
  echo "  → Add/list/remove feature workspaces from the korlap GUI instead."
  echo "  → /jj-workflow is disabled here to avoid two competing parallel-workspace models."
  echo ""
  echo "Marker: .korlap/marker.json (korlap version $version)"
  exit 0
fi
```

Why: korlap writes this marker on first successful bootstrap when the user picks Claude Code + GUI during `/onboard`. korlap uses bare git worktrees for per-feature isolation, driven from its kanban UI. Running `/jj-workflow new` on top of that would create a parallel, inconsistent isolation model in the same directory. The skill stays installed (so uninstalling korlap later restores JJ behavior) but is inert while korlap claims the workspace.

## Commands

### `/jj-workflow init`

Initialize JJ colocated mode in all service repos. Can be run standalone or during onboarding.

**Steps:**
1. Check JJ is available:
   ```bash
   command -v jj &>/dev/null && echo "✓ jj available: $(jj --version)" || echo "✗ jj not found"
   ```
2. If JJ not found, STOP:
   > "JJ (Jujutsu) is not installed. Install with `brew install jj` or add it via Nix (`nix develop`), then retry."
3. For each service directory that has `.git/` but NOT `.jj/`:
   ```bash
   for service in api web ai-service data-service; do
     if [ -d "$service/.git" ] && [ ! -d "$service/.jj" ]; then
       echo "Initializing JJ colocated mode in $service/"
       cd "$service" && jj git init --colocate && cd ..
     elif [ -d "$service/.jj" ]; then
       echo "✓ $service/ already has JJ initialized"
     elif [ ! -d "$service" ]; then
       echo "○ $service/ does not exist — skipping"
     fi
   done
   ```
4. Report results:
   ```
   JJ colocated mode initialized:
     ✓ api/      — jj git init --colocate
     ✓ web/      — jj git init --colocate
     ✓ ai-service/ — already initialized
     ○ data-service/ — directory not present
   ```
5. Update `.onboard-state.json` if it exists: set `jj_available: true`

### `/jj-workflow new <slug>`

Create a new JJ workspace for parallel feature development.

**Steps:**
1. **Validate preconditions:**
   - Check JJ is available (`command -v jj`)
   - Read `.workflow-state.json` — check that `workspace_meta` does NOT exist (must be run from primary workspace)
   - If `workspace_meta` exists: STOP — "This is a secondary workspace. Create new workspaces from the primary workspace only."
   - Validate `<slug>` format: lowercase alphanumeric with hyphens (`^[a-z0-9]+(-[a-z0-9]+)*$`)

2. **Determine workspace name and path:**
   - Workspace name: `<current-dir-name>-<slug>` (e.g., `frndos-feature-b`)
   - Path: `../<workspace-name>/` (sibling directory)
   - Check path doesn't already exist

3. **Create the workspace directory:**
   ```bash
   mkdir -p "../<workspace-name>"
   ```

4. **Create JJ workspaces in each service repo that has `.jj/`:**
   ```bash
   for service in api web ai-service data-service; do
     if [ -d "$service/.jj" ]; then
       echo "Creating JJ workspace for $service/"
       cd "$service"
       jj workspace add "../../<workspace-name>/$service" --name "<slug>"
       cd ..
     fi
   done
   ```
   This creates a new JJ working copy in the sibling directory for each service, sharing the same commit graph.

5. **Symlink orchestration files** from primary to secondary workspace:
   ```bash
   cd "../<workspace-name>"
   for item in .agentic-workflows .agents AGENTS.md CLAUDE.md .claude flake.nix run-all.sh docs .onboard-state.json; do
     if [ -e "../<primary-name>/$item" ]; then
       ln -sf "../<primary-name>/$item" "$item"
     fi
   done
   ```
   Note: `CLAUDE.md` is already a symlink to `AGENTS.md` — symlink it to the primary's `AGENTS.md` directly.

6. **Create fresh `.workflow-state.json`** in the new workspace with `workspace_meta`:
   ```json
   {
     "active_feature": null,
     "worker": "<current-worker>",
     "features": {},
     "workspace_meta": {
       "primary_workspace": "../<primary-name>",
       "feature_slug": "<slug>",
       "is_jj_workspace": true
     }
   }
   ```

7. **Register in primary workspace's `.workflow-state.json`:**
   - Add to `workspaces` map:
     ```json
     "workspaces": {
       "<slug>": {
         "path": "../<workspace-name>",
         "created": "<ISO8601-now>",
         "worker": "<current-worker>"
       }
     }
     ```

8. **Tell the user:**
   ```
   JJ workspace created at ../<workspace-name>/

   To start working:
     1. Open a NEW terminal
     2. cd ../<workspace-name>/
     3. Start a new Claude Code session
     4. Run /workflow start <slug> to begin your feature

   The workspace shares the same git commit graph — committed changes
   in either workspace are immediately visible in the other.

   ⚠ Port conflicts: You cannot run the same services in both workspaces
   simultaneously. Stop services in one workspace before starting them
   in the other.
   ```

### `/jj-workflow list`

List all JJ workspaces and their current features/phases.

**Steps:**
1. **Find the primary workspace:**
   - Read `.workflow-state.json`
   - If `workspace_meta` exists → this is secondary. Primary is at `workspace_meta.primary_workspace`
   - If no `workspace_meta` → this is primary

2. **Read the workspaces map from primary:**
   - Read primary's `.workflow-state.json`
   - Get the `workspaces` map (may be empty or absent)

3. **For each workspace, read its state:**
   - Read `<path>/.workflow-state.json`
   - Extract: active feature, phase, worker

4. **Display table:**
   ```
   JJ Workspaces:

     Path                          Feature              Phase              Worker
     ───────────────────────────── ──────────────────── ────────────────── ──────
   ★ ../frndos/                    image-editor         pr_review          arhen     (primary)
     ../frndos-feature-b/          feature-b            prd_creation       arhen
     ../frndos-analytics/          user-analytics       implementation     daffa

   ★ = current workspace
   ```

5. If no workspaces registered: "No JJ workspaces found. Use `/jj-workflow new <slug>` to create one."

### `/jj-workflow status`

Show current workspace info and JJ state.

**Steps:**
1. **Determine workspace type:**
   - Read `.workflow-state.json`
   - If `workspace_meta` exists → secondary workspace
   - Otherwise → primary workspace

2. **Display workspace info:**

   For primary:
   ```
   Workspace: PRIMARY
   Path: /path/to/frndos/
   Active feature: image-editor (pr_review)
   Registered workspaces: 2
   ```

   For secondary:
   ```
   Workspace: SECONDARY (JJ workspace)
   Path: /path/to/frndos-feature-b/
   Primary: ../frndos/
   Feature scope: feature-b
   Active feature: feature-b (prd_creation)
   ```

3. **Show JJ workspace state per service repo:**
   ```bash
   for service in api web ai-service data-service; do
     if [ -d "$service/.jj" ]; then
       echo "=== $service ==="
       cd "$service" && jj workspace list && cd ..
     fi
   done
   ```

### `/jj-workflow cleanup <slug>`

Remove a completed JJ workspace.

**Steps:**
1. **Must be run from primary workspace:**
   - Read `.workflow-state.json`
   - If `workspace_meta` exists: STOP — "Run cleanup from the primary workspace."

2. **Validate the workspace exists:**
   - Check `workspaces.<slug>` exists in state
   - Read the workspace path

3. **Check feature status:**
   - Read `<path>/.workflow-state.json`
   - If feature is not in `completion` or `idle` phase, ask for confirmation:
     > "Feature `<slug>` is in phase `<phase>` (not complete). Are you sure you want to remove this workspace?"
     > - Yes, remove it anyway
     > - No, keep it

4. **Forget JJ workspaces in each service repo:**
   ```bash
   for service in api web ai-service data-service; do
     if [ -d "$service/.jj" ]; then
       cd "$service"
       jj workspace forget "<slug>" 2>/dev/null || echo "$service: workspace '<slug>' not found (already cleaned)"
       cd ..
     fi
   done
   ```

5. **Remove the workspace directory:**
   ```bash
   rm -rf "<workspace-path>"
   ```

6. **Update primary's `.workflow-state.json`:**
   - Remove `<slug>` from `workspaces` map

7. **Confirm:**
   ```
   Workspace '<slug>' cleaned up:
     ✓ JJ workspaces forgotten in api/, web/, ai-service/
     ✓ Directory ../frndos-<slug>/ removed
     ✓ Removed from workspaces registry
   ```

## Rules

- **JJ colocated mode only** — git commands remain unchanged everywhere. JJ is used exclusively for `workspace add`, `workspace list`, `workspace forget`.
- **JJ is NOT used for commits, branches, or diffs** — all version control operations go through git.
- **Terminal-based harnesses** (Claude Code, Amp) benefit most — they run one session per directory. Cursor (IDE-integrated) benefits less; OpenCode also works per-session if desired.
- **Each workspace is independent** — no cross-workspace phase dependencies. A feature in workspace B doesn't wait for workspace A.
- **Committed changes propagate instantly** — since JJ workspaces share the same repo graph, any `git commit` in one workspace is immediately visible via `git log` in another.
- **Port conflicts** — you cannot run the same services (e.g., two API servers on :9191) in two workspaces simultaneously. Stop services in one before starting in the other.
- **No nested workspaces** — secondary workspaces cannot create further workspaces. Only the primary workspace can create new ones.
- **Cleanup when done** — when a feature is complete, clean up with `/jj-workflow cleanup <slug>` to free disk space and remove stale JJ workspace references.
