## Agent Teams (Parallel Implementation)

When Claude Code's Agent Teams are available, the `implementation` phase uses parallel per-service engineers instead of a single sequential `frndos-implement` agent.

**Detection — env var, NOT Agent tool:**
- Check `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` env var
- If `1`: Agent Teams is enabled — use natural language team creation
- Otherwise: fall back to sequential flow (frndos-implement → frndos-pr)
- Cursor, OpenCode, and Amp always use the sequential fallback (Amp subagents have no inter-agent communication, so parallel Agent Teams is infeasible there)

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
