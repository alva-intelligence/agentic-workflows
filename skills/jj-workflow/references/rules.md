## JJ Workspace Rules (Parallel Features)

When JJ (Jujutsu) is available and the user wants to work on multiple features simultaneously, they can use `/jj-workflow` to create isolated working directories.

**Colocated mode — git unchanged:**
- JJ runs in colocated mode alongside git. All git commands (commit, push, branch, merge) work exactly as before.
- JJ is used ONLY for workspace management: `jj workspace add`, `jj workspace list`, `jj workspace forget`.
- JJ does NOT replace git for commits, branches, or diffs.

**Best with terminal-based harnesses:**
- JJ workspaces create separate working directories — useful for Claude Code and Amp sessions running in parallel terminals.
- Cursor is IDE-integrated so benefits less; OpenCode also runs per-session and can use workspaces if desired.

**Independence:**
- Each workspace operates independently. A feature in workspace B does not wait for workspace A.
- Each workspace has its own `.workflow-state.json` with its own feature state machine.
- The workflow phase machine is unchanged — all 11 phases work identically in any workspace.

**Commit propagation:**
- Since JJ workspaces share the same underlying repo graph, committed changes in one workspace are immediately visible in the other via `git log` or `git pull`.
- Uncommitted changes are isolated per workspace.

**Port conflicts:**
- The same services (e.g., API on :9191, Frontend on :3000) CANNOT run in two workspaces simultaneously.
- Stop services in one workspace before starting them in the other, or configure different ports.

**Workspace hierarchy:**
- Only the **primary workspace** can create new workspaces (`/jj-workflow new <slug>`).
- Secondary workspaces CANNOT create nested workspaces.
- Cleanup (`/jj-workflow cleanup <slug>`) must be run from the primary workspace.

**Lifecycle:**
- Create: `/jj-workflow new <slug>` from primary workspace
- Work: open a new Claude Code or Amp session in the new directory, run `/workflow start <slug>` (or say "start feature `<slug>`" in Amp)
- Complete: finish the feature normally, merge PRs
- Clean up: `/jj-workflow cleanup <slug>` from primary workspace

**Secondary-workspace detection:** Check `.workflow-state.json` for `workspace_meta.is_jj_workspace`:
- If `true` → this is a **secondary JJ workspace**, scoped to one feature. The session is limited to the feature in `workspace_meta.feature_slug`.
- If `false` or absent → this is the **primary workspace** (or a non-JJ workspace). Check `command -v jj` to detect JJ availability for later use (e.g., suggesting `/jj-workflow new` when starting parallel features).
