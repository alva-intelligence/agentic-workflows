## Korlap frndOS Workflow GUI - Complete (Branch: feature/arhen/vc-frndos-workflow-gui)

### Build Status
- Rust: 0 errors, 7 warnings
- TypeScript: 0 errors, 25 warnings

### All Changes Summary

**Backend (Rust - src-tauri/)**
- `state.rs`: WorkflowPhase, TaskType enums; extended WorkspaceInfo with phase, task_type, skip_wireframe, feature_slug, jj_workspace_path
- `commands/agent.rs`: Claude-only, phase-aware system prompts, removed Codex/provider switching
- `commands/agent_backend.rs`: Phase-aware permissions (--auto vs --permission-mode plan), pub methods
- `commands/workspace.rs`: bind_workspace, discover_workspaces, advance_phase, update_jj_workspace_path
- `commands/repo.rs`: is_workflow_workspace field in RepoDetail (via flattened RepoInfo)
- `commands/staging.rs`: Updated WorkspaceInfo fields
- `lib.rs`: Updated command registrations

**Frontend (TypeScript/Svelte - src/)**
- `lib/ipc.ts`: WorkflowPhase, TaskType types; bindWorkspace, discoverWorkspaces, advancePhase IPC calls; WorkspaceInfo with phase fields; RepoDetail with is_workflow_workspace
- `lib/components/kanban/KanbanBoard.svelte`: 8 columns (Todo + 7 phases), horizontal scroll, sticky Todo, workspaces grouped by phase
- `lib/components/kanban/KanbanColumn.svelte`: Fixed width 280px, sticky prop
- `lib/components/kanban/KanbanCard.svelte`: Shows task_type badge, simplified
- `lib/components/kanban/CardDetailOverlay.svelte`: Phase badge, advance phase button, feature_slug, PRD URL
- `lib/components/kanban/TaskPopover.svelte`: Workflow mode with task_type selector, skip_wireframe toggle, prd_url input
- `lib/components/workspace/WorkspacePanel.svelte`: Phase badge in breadcrumb
- `routes/+page.svelte`: handleAdvancePhase, bind_workspace integration, discover_workspaces on workflow repo selection, workflow-aware handleNewTodoAndStart

### Key Workflows
1. **Create task**: TaskPopover with type (Feature/Bug/Improvement), PRD URL, skip wireframe → calls bind_workspace
2. **Advance phase**: Card detail overlay → "Advance to Next Phase" button → calls advance_phase
3. **Discover workspaces**: Selecting workflow repo auto-discovers from .workflow-state.json
4. **Phase-aware agent**: --permission-mode plan for prd_creation, --auto for all other phases