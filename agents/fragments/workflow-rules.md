## Workflow Rules (STRICT ENFORCEMENT)

### 10-Phase State Machine

```
idle → prd_creation → wireframe → wireframe_review → branch_creation
     → prd_splitting → implementation → pr_submission → pr_review → completion → idle
```

### Phase Transition Rules

1. **NEVER skip a phase.** If user asks to skip, respond: "I cannot skip phases. Current phase: [PHASE]. Required gate: [GATE]."
2. **NEVER create a feature branch before wireframe approval.**
3. **NEVER start implementation before service PRDs exist.**
4. **NEVER modify develop/development branch directly.** All work happens on feature branches.
5. **CHECK `.workflow-state.json` before ANY work.**
6. **UPDATE `.workflow-state.json` after every phase transition.**

### Gate Conditions

| Transition | Gate | Check Method |
|-----------|------|-------------|
| prd_creation → wireframe | PRD file exists with required frontmatter + sections | File check |
| wireframe → wireframe_review | Wireframe directory exists with ≥1 .tsx file | File check |
| wireframe_review → branch_creation | Approval recorded (verbal confirmation from Jeff) | Manual confirmation |
| branch_creation → prd_splitting | Feature branch exists from latest develop | Git check |
| prd_splitting → implementation | Service PRDs exist for each touched service | File check |
| implementation → pr_submission | Track file shows progress | File check |
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

### Multiple Wireframes per PRD

- `wireframes` is an array — a PRD can have multiple wireframes
- Each wireframe has its own `slug`, `owner`, and `approval` status
- `wireframe_review` gate requires ALL wireframes to be approved
- Only the wireframe owner (or unassigned) can create/edit a wireframe

### Always Ask Before Executing

**MANDATORY for every agent:** Before performing ANY action:
1. **Explain** what you plan to do and why
2. **Ask questions** if anything is unclear
3. **Give suggestions** if there are multiple valid approaches
4. **Wait for user confirmation** before executing

NEVER execute code changes without explaining the plan first.
NEVER make assumptions about requirements without asking.
NEVER skip the confirmation step, even for "obvious" actions.
NEVER auto-proceed after presenting a plan — always wait for explicit approval.
