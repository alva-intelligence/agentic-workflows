## Workflow Rules (STRICT ENFORCEMENT)

### 11-Phase State Machine

```
idle → prd_creation → wireframe → wireframe_pr → wireframe_review → branch_creation
     → prd_splitting → implementation → pr_submission → pr_review → completion → idle
```

### Phase Transition Rules

1. **NEVER skip a phase.** If user asks to skip, respond: "I cannot skip phases. Current phase: [PHASE]. Required gate: [GATE]."
2. **NEVER create a feature branch before wireframe PR is merged.**
3. **NEVER start implementation before service PRDs exist.**
4. **NEVER modify develop/development branch directly.** Wireframes go on `wireframe/<worker>/vc-<slug>` branch, features on `feature/<worker>/vc-<slug>` branch.
5. **CHECK `.workflow-state.json` before ANY work.**
6. **UPDATE `.workflow-state.json` after every phase transition.**
7. **CHECK current git branch matches the expected branch for the phase** before doing any work.

### Branch per Phase

| Phase | Expected Branch |
|-------|----------------|
| prd_creation | any (PRDs are in docs/, not branch-specific) |
| wireframe | `wireframe/<worker>/vc-<slug>` (created from develop) |
| wireframe_pr | `wireframe/<worker>/vc-<slug>` (PR targets develop) |
| wireframe_review | `wireframe/<worker>/vc-<slug>` (waiting for PR merge) |
| branch_creation | `develop` → creates `feature/<worker>/vc-<slug>` |
| prd_splitting → completion | `feature/<worker>/vc-<slug>` |

### Gate Conditions

| Transition | Gate | Check Method |
|-----------|------|-------------|
| prd_creation → wireframe | PRD file exists with required frontmatter + sections | File check |
| wireframe → wireframe_pr | Wireframe dir exists with .tsx + metadata.json, changes committed on `wireframe/<worker>/vc-<slug>` | File + Git check |
| wireframe_pr → wireframe_review | Wireframe PR exists targeting develop | `gh` check |
| wireframe_review → branch_creation | Wireframe PR merged + Jeff approved | `gh` check + Manual confirmation |
| branch_creation → prd_splitting | On `develop`, pulled latest, wireframe files verified, `feature/<worker>/vc-<slug>` created | Git check |
| prd_splitting → implementation | Service PRDs exist, on `feature/<worker>/vc-<slug>` | File + Git check |
| implementation → pr_submission | Track file shows progress, on `feature/<worker>/vc-<slug>` | File + Git check |
| pr_submission → pr_review | PR URL recorded and exists on GitHub | `gh` check |
| pr_review → completion | PR merged | `gh` check |
| completion → idle | Track file marked complete | File check |

### Context Switching

- Use `/workflow switch <feature-slug>` to switch between active features
- Each feature maintains its own phase independently
- When switching, the agent saves current state, loads target feature's state, and prompts for branch switch if needed

### Team Member Handoff

When picking up another person's feature:
1. Use `/workflow resume <slug>`
2. Agent scans committed artifacts to reconstruct the phase
3. Agent populates local `.workflow-state.json` with reconstructed state
4. Continue from where the previous person left off

### Wireframes and Sub-Pages

A wireframe = **one feature page**. Sub-views (create form, detail page, wizard steps) are sub-pages within the same wireframe directory, not separate wireframes.

- `wireframes` is an array, but most PRDs have **one wireframe** with sub-pages inside it
- Each wireframe has its own `slug`, `owner`, and `approval` status
- `wireframe_review` gate requires ALL wireframes to be approved
- Only the wireframe owner (or unassigned) can create/edit a wireframe
- Do NOT create separate wireframes for sub-views — a "Create" page is a sub-page of the listing wireframe, not its own wireframe
- Multiple wireframes per PRD is rare — only when the PRD describes truly independent feature pages

### Agent Teams (Parallel Implementation)

When Claude Code's Agent Teams are available, the `implementation` phase uses parallel per-service engineers instead of a single sequential `frndos-implement` agent.

**Detection — env var, NOT Agent tool:**
- Check `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` env var
- If `1`: Agent Teams is enabled — use natural language team creation
- Otherwise: fall back to sequential flow (frndos-implement → frndos-pr)
- Cursor/OpenCode always use the sequential fallback

**Mechanism — natural language team creation:**
- The lead creates the entire team via a single natural language prompt describing all teammates
- Each teammate is a persistent session (NOT a subagent) with its own context
- Teammates are spawned with their instruction file path in the spawn prompt
- Teammates load CLAUDE.md and read their instruction files on startup

**Shared task list:**
- The lead creates a shared task list with per-service task chains and dependencies
- Chain per service: `plan → implement → self-review → architect-review → pr`
- Dependencies enforce ordering within each chain

**Mailbox messaging:**
- All inter-teammate communication uses the mailbox
- `message` for 1:1 (lead ↔ engineer, architect ↔ engineer)
- `broadcast` for all teammates (use sparingly)

**Plan approval — built-in:**
- Teammates spawned with plan approval required start in **read-only plan mode**
- They automatically present their plan and request approval
- Lead reviews and approves — engineer stays read-only until approved
- This prevents scope creep and ensures alignment with service PRDs

**Transition shortcut:**
- Agent Teams: `implementation` → `completion` (skips `pr_submission` + `pr_review`)
- Each engineer handles their own PR creation — the lead doesn't need a separate PR phase

**Fallback:**
- If Agent Teams is not available, `implementation` → `pr_submission` → `pr_review` → `completion` (unchanged)

**Cross-service communication:**
- Engineers CAN read other service directories for context
- Engineers MUST NOT write code outside their assigned service
- Architect reviews integration across services as engineers finish

**Self-review mandate:**
- Every engineer MUST self-review their own code before notifying the lead
- Self-review covers: bugs, patterns, conventions, security
- Architect review covers: cross-service integration only (NOT code quality)

**Team cleanup:**
- When all engineers report done, the lead MUST shut down all teammates
- After shutting down teammates, the lead runs "Clean up the team"
- Only then does the lead transition to `completion` phase

**Limitations:**
- One team per session — do NOT create multiple teams
- No session resumption for in-process teammates — if a session is lost, the teammate must be re-created

**Engineer status flow:**
```
pending → planning → implementing → self_reviewing → architect_review → creating_pr → pr_feedback → done
```

### Always Ask Before Executing

**MANDATORY for every agent:** Before performing ANY action:
1. **Explain** what you plan to do and why
2. **Ask questions** if anything is unclear — **use the ask tool** (see below)
3. **Give suggestions** if there are multiple valid approaches
4. **Wait for user confirmation** before executing

**Use the ask tool for ALL user input.** Do NOT just print questions as plain text. Use your tool's dedicated ask mechanism:
- **Claude Code:** `AskUserQuestion` tool with structured options
- **Cursor:** Built-in ask question tool
- **OpenCode:** Question tool with select/text modes

This ensures the agent blocks until the user responds and prevents accidentally proceeding without input.

NEVER execute code changes without explaining the plan first.
NEVER make assumptions about requirements without asking.
NEVER skip the confirmation step, even for "obvious" actions.
NEVER auto-proceed after presenting a plan — always wait for explicit approval.

### Steps requiring sudo or external terminal

Some steps (Nix installation, system config changes, etc.) require `sudo` or an interactive terminal that the agent cannot provide. For these:

1. **Tell the user exactly what to run** in a separate terminal
2. **Use the ask tool** to ask if they've completed it
3. **DO NOT proceed** until user confirms — use the ask tool to block
4. **Verify** the step actually worked (e.g., `command -v nix`) before moving on
5. If verification fails, ask again — do NOT skip the step
