---
name: workflow
description: Manage feature workflow state — three human checkpoints, automatic preparation, status, transitions, context switching
---

# Workflow Manager

Manages the feature development workflow state machine.

## References (load when needed)

- `references/track-conventions.md` — Track-file location, frontmatter, plan/verification/evidence sections, review-watch persistence, session-log rules. Read when preparing tracks, entering implementation, updating progress, or monitoring delivery.
- `references/testing-policy.md` — Verification rules. Read before writing tests or running checks.
- `references/session-checks.md` — Session-time procedures (feature branch recency check, service health checks, update-check + sync + conflict handling). Read when the session-start protocol in `AGENTS.md` delegates here.

## Three human checkpoints

Only three moments need a person. Everything between them is automatic preparation or verified execution.

| Checkpoint | Phase position | Authority | What it authorizes |
|---|---|---|---|
| **Scope** | end of `brainstorming` | `scope_approved: true` | Preparation only: PRDs, branch, tracks, plans. Never code changes. |
| **Implementation** | after preparation, before the first code change | `implementation_approved: true` or `automation.implementation: true` | Writing, changing, or deleting project code. |
| **Delivery** | after independent verification | `delivery: "local_test" \| "open_pr" \| "auto_merge"`; `live_merge_approved: true` separately for live estates | What happens to the verified work. |

- `phase_status: "completed"` means the phase's artifacts and checks are satisfied. It does **not** authorize crossing any checkpoint.
- Scope approval, implementation auto-start, and merge consent are independent. `automation.brainstorming` alone never authorizes code changes; `delivery: "auto_merge"` alone never authorizes a live-estate merge.
- When a checkpoint field is absent, apply its safe default. Missing authorization fails closed.
- Do not re-ask a checkpoint the user already approved or preauthorized. Record the approval once and continue.

## State contract

Optional per-feature fields. All are safe when absent; an existing `.workflow-state.json` without them stays valid and must not be rewritten just to add them. Write the full contract on `/workflow start`, read absent fields as the defaults below.

```json
{
  "scope_approved": false,
  "automation": { "brainstorming": false, "implementation": false },
  "execution_mode": null,
  "implementation_approved": false,
  "delivery": null,
  "live_merge_approved": false
}
```

| Field | Values | Default | Set by | Meaning |
|---|---|---|---|---|
| `scope_approved` | boolean | `false` | Scope checkpoint | Scope is agreed. Permits preparation only. |
| `automation.brainstorming` | boolean | `false` | Explicit user instruction | Agent may auto-approve scope and auto-pick the recommended option for reversible, evidence-backed scope choices. Destructive, taste-based, or expensive-to-reverse unresolved scope changes still stop for the user. |
| `automation.implementation` | boolean | `false` | Explicit user instruction | Implementation entry is preauthorized after preparation; no second ask. Independent of scope approval. |
| `execution_mode` | `"main"` \| `"subagents"` \| `null` | `null` | Resolved by the agent before implementation; user may override | How implementation is executed. Not consent. |
| `implementation_approved` | boolean | `false` | Implementation checkpoint or `automation.implementation: true` | Code changes are authorized. |
| `delivery` | `"local_test"` \| `"open_pr"` \| `"auto_merge"` \| `null` | `null` | User instruction only, per feature/task | What happens after verification. Never defaulted, never inferred from artifacts, never copied from another task or a global default. A verified, explicitly persisted consent for the same task survives a resume; do not re-ask it. |
| `live_merge_approved` | boolean | `false` | Separate explicit user approval for this task | Merge into a data-pipeline branch, which is a live Prefect estate even on `development`. |

`automation` has no other properties. Do not invent flags; if the user grants some other standing permission, record it in the track and the relevant `verification` entry instead.

Keep the existing `verification` string map for plan references, evidence, head-specific review results, and final verdicts. Keep the existing required `agent_state` / `agent_state_reason` pair: both `null` together, or `agent_state` non-null with a non-empty reason. Review-monitoring limits, deadline, and round counts live in the track, not in a new state engine.

## Automatic preparation after scope approval

Once `scope_approved` is true, preparation runs automatically:

- **Feature:** `prd_creation` writes the main PRD, then `prd_splitting` creates the branch locally, writes every service PRD, and prepares each track with its task plans and verification plans. The workflow then enters `implementation` for the implementation checkpoint.
- **Bug / improvement (hotfix is a bug):** `implementation` entry creates the branch locally, then prepares the track(s) with task plans and verification plans. The workflow then stops at the implementation checkpoint.
- No per-document approvals, no draft-review loops, no `/workflow next` ceremony. The user sees one preparation summary at the implementation checkpoint.
- Create the branch locally only. Do **not** push it before implementation approval unless the user explicitly asked for that push. Push after implementation approval, when implementation starts.
- If preparation hits a genuinely unresolved product or scope decision, gather it into one ask and resume preparation after the answer. Record decisions the agent made itself in `brainstorming.decisions[]` and in the PRD's decisions section.
- User-requested skips are recorded and respected — for example `brainstorming.user_skipped: true` plus a `brainstorming.decisions[]` entry naming the skipped artifact. A skip waives artifact creation, never a checkpoint guard.
- **Skipped main PRD on a feature:** record the skip in `brainstorming.decisions[]` and the track, then prepare service tracks from the approved scope summary. Do not fabricate a PRD. A gate that expects the skipped file is recorded as a user-authorized exception; scope, implementation, and delivery checkpoints are unaffected.

## Implementation checkpoint

After preparation, present one compact package:

- Scope summary and the source of scope approval.
- Branch, services, and track paths.
- Per-task plan + verification plan.
- Resolved `execution_mode` and the reason for it.
- Risks and anything that could not be decided from evidence.
- The delivery choice is not part of this request unless the user already gave one.

Then ask once whether to start implementation. The same ask may collect an execution-mode override or a delivery preauthorization. If `implementation_approved` or `automation.implementation` is already true, do **not** ask — record the entry and start.

On approval: set `implementation_approved: true`, clear `agent_state` / `agent_state_reason`, push the branch, and implement. `execution_mode` resolution:

- `feature` and `improvement` default to `subagents`.
- `bug` (including hotfix) defaults to `main`.
- Trivial or tightly coupled work may stay `main` for any type; record the rationale.
- A complex bug may be implemented by `subagents`; recommend it in the implementation package.
- A user override wins and is recorded. Do not ask again once the mode is resolved, decided, or overridden.

## Technical lead contract

The main agent is the technical lead. It owns planning, independent verification, and the final verdict; subagents only execute delegated units.

- **Evidence, not claims.** A subagent "done" is a claim. Re-run the checks, read the diff against the task, and reproduce the behavior yourself. Record commands/actions and observed results. Never describe checks or tests as "formal verification" or "formal proof".
- **Plan + verification plan for every task, scaled to risk.** Before implementation, each task gets a short plan (approach, touched areas, dependencies, risks) and a verification plan (expected evidence, exact checks, risk level).

  | Risk | Typical signal | Verification plan |
  |---|---|---|
  | Low | copy, small isolated UI change | targeted lint/type check, smoke/manual check of the touched surface |
  | Medium | normal endpoint/component/flow change | targeted existing tests, lint, behavior check, minimal regression around the touched path |
  | High | auth, data migrations, live-estate pipeline, cross-service contract | adversarial review, broader minimal regression, explicit rollback/recovery check |

- **Adversarial review and final helicopter review.** Use an independent reviewer (a fresh subagent or a separate pass) to attack the change, then personally review the whole diff end to end before the delivery checkpoint. Record both outcomes in `verification` and the track.
- **Resources.** Before intensive work (browser automation, builds, migrations, data jobs), check disk, memory, and CPU headroom. Bound concurrency. Release only resources the task owns (processes, ports, tabs, temp files); never kill shared infrastructure.
- **TODO reconciliation.** Update the task checklist after each completed task. Before the final report, reconcile the checklist and the original request: every requested item accounted for, nothing extra silently added.
- **Intercom.** If the current harness supports parent-child or sibling messaging, use it for interface details and steering. Otherwise all coordination routes through the main agent.

## Verification policy

No dependency is added for testing. Existing targeted tests, lint, type checks, build checks, and minimal regression checks are permitted and are the default evidence. New test files, suites, frameworks, or test dependencies require an explicit user request for this task. Never run an entire suite when a targeted check answers the question. Full rules: `references/testing-policy.md`.

## Delivery checkpoint

Delivery happens only after independent verification is complete and recorded. If `delivery` is set for this feature or task, honor it and do not ask again. If it is `null`, ask once at the checkpoint. If the user gives no delivery instruction, do not open a PR, do not merge, and do not mark the task complete — stop and keep the feature resumable.

| Delivery | Result |
|---|---|
| `local_test` | Verified work is run locally **first**, with automatic checks already complete. Give the user the URL/path and the exact steps to test the local flow manually; keep the requested server running and keep the branch. Do not mark the task complete, do not clean up the branch/server, and do not run `pr_submission` yet: `pr_submission` stays pending. After the user reports the manual result, they choose `open_pr` or `auto_merge` (or another local test round); record the final choice and continue through the normal phases. |
| `open_pr` | Run `pr_submission` (self-review + security audit), open the PR, address review feedback, and hand it to the human owner. Do not merge. Completion waits for the human merge. |
| `auto_merge` | Run the PR pipeline, monitor the PR within the bounded watch, fix valid feedback, and merge only when every condition below holds. |

- `delivery` is user instruction only. It is not inferred from a branch, PRD, track, PR, or a reconstructed feature state. A verified explicit consent persisted for the **same task** survives resume; a previous task's consent never carries to another task, and no global default exists.
- When the user reports the manual result and chooses `open_pr` or `auto_merge`, record the new `delivery` and continue automatically into `pr_submission` — no `/workflow next` ceremony. Keep the normal `implementation → pr_submission → [pr_review] → completion` routes.
- When a feature spans several services, a per-task instruction is recorded in that service's track and applies only to that task. Never widen one task's authorization to another.
- **Live estates.** `data-pipeline` is live even on its development branch: a merge is deployable/running work. `delivery: "auto_merge"` is not enough. Require a separate explicit approval for that task, record `live_merge_approved: true`, and state plainly that merging affects the live estate. Promotion to production remains separate human work; never perform it or bypass it.

## Auto-merge gate

`delivery: "auto_merge"` authorizes a monitored merge attempt, not an unconditional merge. All conditions must hold on the current head:

1. **Authority.** `delivery` is explicitly `auto_merge` for this feature/task; `implementation_approved` is true; for a live estate `live_merge_approved` is true. Missing any authorization means no merge.
2. **Full feedback inventory.** Paginate every review-thread page and every PR-level comment/review. All threads are resolved; resolve only threads actually addressed. Any open change request or unaddressed finding blocks the merge. A zero-thread inventory before the configured expected review has completed is **not** completion — wait for the review.
3. **Required checks and review on the latest head.** All required CI checks passed on the latest commit. The review the repository actually requires (required approvals, CODEOWNERS, bot review) has completed on that same head.
4. **Approvals current.** No `CHANGES_REQUESTED`, required approvals present for the latest head, no merge conflicts, and every branch protection satisfied.
5. **Proof package clean.** Self-review, security audit, adversarial review, and the final whole-change helicopter review are recorded with no must-fix items and no high/critical findings.
6. **Head-specific proof.** Every push invalidates prior head-specific proof. Re-read the latest head SHA and re-run the merge-critical checks immediately before merging; record the SHA.
7. **No bypass.** Never bypass branch protections, never admin-merge, never force-push a shared branch, never disable or skip a required check.
8. **Native mechanisms.** Prefer a native auto-merge or merge queue only when it enforces these same conditions. Otherwise wait for the checks and merge normally.

If any condition fails, do not merge. Report the failed condition, pause the delivery, and keep the state resumable.

## Bounded review watch

- Default budget: **30 minutes** and **3 fix rounds**, unless the user overrides it for this task.
- Persist the watch in the track: status (`not_started` / `watching` / `paused` / `done` / `expired`), deadline, max rounds, rounds used, last checked SHA, and the next action.
- Each fix round = address feedback, push, re-verify, re-inventory. Every push resets head-specific proof.
- On timeout, exhausted rounds, or session end: mark the watch `paused` or `expired` in the track with the exact next action. Never claim background monitoring continues; resume later from the persisted state.
- Resume starts from the persisted watch state: keep the original deadline and `rounds_used` unless the user explicitly grants a new budget. Do not reset the clock or the round count.

## `phase_status`, authority, and auto-advance

- `phase_status`: `idle` (entered, not started) → `inprogress` (agent working) → `completed` (phase artifacts/checks satisfied).
- Preparation phases auto-advance after scope approval. There is no blanket "never auto-advance" rule and no mandatory `/workflow next` between `prd_creation`, `prd_splitting`, and implementation preparation.
- Checkpoints still stop work even when `phase_status` is `completed`. Never cross a checkpoint by setting a phase status or by running `/workflow next`.
- `/workflow next` remains available for an explicit, gate-checked transition. It is not required for automatic preparation and cannot substitute for an approval flag.
- User-requested skips are recorded; they do not bypass scope, implementation, or delivery guards.

## Commands

### `/workflow status`
Show the current workflow state for the active feature.

**Steps:**
1. Read `.workflow-state.json`.
2. Display:
   - Active feature: `{active_feature}`
   - Current phase: `{phase}` and `phase_status` (`idle` / `inprogress` / `completed`)
   - Phase entered: `{phase_entered}`
   - Worker: `{worker}`
   - Type: `{type}` (feature | bug | improvement; a hotfix is stored as `bug`)
   - Checkpoints: Scope (`approved` / `pending`), Implementation (`approved` / `pending` / `automation`), Delivery (`local_test` / `open_pr` / `auto_merge` / `not chosen`; `local_test` while a manual test is pending), Live merge (`approved` / `not approved`, only relevant on a live estate)
   - Automation: brainstorming / implementation flags (read absent as `false`)
   - Execution mode: `{execution_mode}` or the resolved default with the reason
   - Brainstorming: summary present, number of decisions, number of questions answered
   - Branch: `{branch}` or "not created"
   - Service PRDs and track files, with plan/verification task counts
   - PRs: `{pr_urls}` or "not submitted"
   - Review watch: status, deadline, rounds used (from the track)

### `/workflow list`
Show ALL active features with their phases.

**Steps:**
1. Read `.workflow-state.json`.
2. For each feature in `features{}`:
   - Show slug, phase, phase_entered, worker, and the checkpoint that is currently pending.
   - Mark active feature with `→`.

### `/workflow start <slug>`
Start a new feature workflow.

**Steps:**
1. **Check onboarding state first.** Read `.onboard-state.json`:
   - If file doesn't exist and no service directories → BLOCK: "Run `/onboard` first."
   - If `status` is `"in_progress"`, check critical steps:
     - `steps.env_files` must be `"completed"` (every service that needs a `.env` has a real one).
       A service whose `env_status` is `"n/a"` is **satisfied, not pending** — it has no `.env` by
       design (data-pipeline uses Prefect Secret blocks), so it must not hold this field back.
     - `steps.db_setup` must be `"completed"` (if API service is selected)
     - `steps.clone_repos` must be `"completed"`
     - `steps.install_deps` must be `"completed"`
   - If ANY critical step is missing → BLOCK and list what's needed:
     ```
     Cannot start workflow. Onboarding is incomplete:
       - api/.env is missing — contact arhen
       - Database not restored — contact arhen for dev dump
     Run `/onboard resume` to complete setup.
     ```
   - If `status` is `"completed"` → proceed.
2. Read `.workflow-state.json` (create if it doesn't exist).
3. Check that `<slug>` doesn't already exist in features.
4. **If an active feature already exists**, offer parallel work via **git worktrees** (no extra tooling — modern agents handle worktrees fine):

   > "You have an active feature (`<active-slug>` in `<phase>`). You can:"
   > - **Continue here** with context-switching (`/workflow switch` between features) — recommended for related work
   > - **Work in parallel** — the new feature gets its own git worktree per affected service repo (`git worktree add <path> -b <prefix>vc-<slug> <base>`), one agent session there

   If the user picks parallel: create the worktrees, key `.workflow-state.json` features by slug, and proceed in the separate directory. Cleanup (`git worktree remove`) at completion.
5. Capture intake via the ask capability:
   - **Type:** feature | bug | improvement. A user saying "hotfix" is stored as `type: "bug"` and the word is kept in `initial_request`; there is no separate hotfix work type.
   - **Initial request:** the user's raw description (free text).
   - Capture automation or delivery preauthorizations only when the user volunteers them. Do not ask for automation flags or a delivery choice at intake.
6. Create the feature entry with the full contract and required pair:
   ```json
   {
     "phase": "idle",
     "phase_status": "completed",
     "phase_entered": "<ISO>",
     "type": "<feature|bug|improvement>",
     "initial_request": "<text>",
     "brainstorming": {
       "questions": [],
       "summary": null,
       "decisions": [],
       "user_skipped": null
     },
     "prd_path": null,
     "branch": null,
     "service_prds": {},
     "pr_urls": {},
     "agent_state": null,
     "agent_state_reason": null,
     "scope_approved": false,
     "automation": { "brainstorming": false, "implementation": false },
     "execution_mode": null,
     "implementation_approved": false,
     "delivery": null,
     "live_merge_approved": false
   }
   ```
   If the user already gave an explicit scope/implementation/delivery instruction, record it in the matching field and note the exact wording in the track or `brainstorming.decisions[]`. A skip request alone is not an approval.
7. Set `active_feature` to `<slug>`. Ask the user for worker name if not set.
8. Save state.
9. Enter `brainstorming` directly (`phase: "brainstorming"`, `phase_status: "idle"`). Do not ask whether to advance; the scope checkpoint is the next human moment. If the user asked to skip brainstorming, load the `brainstorm` skill and apply its skip path.

### `/workflow next`
Explicitly transition to the next phase when the gate and checkpoint conditions are met. This command is optional: automatic preparation already advances phases.

**Steps:**
1. Read `.workflow-state.json`.
2. Get current phase + `phase_status` for active feature.
3. **Require `phase_status === "completed"`.** If `idle` or `inprogress`, refuse: "Phase `<phase>` is not complete yet (`idle`/`inprogress`). Finish the phase work first."
4. Resolve the candidate transition. If more than one exists, use the phase strategy:
   - `brainstorming → prd_creation` for `feature`; `brainstorming → implementation` for `bug|improvement`.
   - `pr_submission → pr_review` when the PR has feedback; `pr_submission → completion` when it merged with no feedback.
5. Enforce checkpoint guards in addition to the file gates:
   - To `prd_creation`: `scope_approved === true`.
   - To `implementation` from `brainstorming` (bug/improvement): `scope_approved === true`. This enters preparation only; code still waits for the implementation checkpoint.
   - To `pr_submission`: `delivery` is `open_pr` or `auto_merge`. If `delivery` is `local_test`, the manual test is pending; do not advance and do not complete the task. If `delivery` is `null`, run the delivery checkpoint first.
   - To `completion` from `pr_submission`/`pr_review`: the PR is merged. For `auto_merge`, the full auto-merge gate passed; for `open_pr`, a human merged. There is no `local_test → completion` shortcut: local testing happens first, then the user chooses `open_pr` or `auto_merge` and the normal routes apply.
6. Check each gate condition in `.agentic-workflows/workflow/gates.json` for the resolved transition. The agent's own checkpoint flags are additional guards, not replacements for file/branch/PR gates.
7. If all pass → transition, update `phase`, `phase_entered`, set new `phase_status` to `"idle"`, save.
8. If any fail → report the failed conditions and what is needed. Do not cross a checkpoint to make a gate pass.

### `/workflow switch <slug>`
Switch active feature context.

**Steps:**
1. Read `.workflow-state.json`.
2. Verify `<slug>` exists in features.
3. Save any pending state for the current feature.
4. Set `active_feature` to `<slug>`.
5. Load the target feature's phase context and its checkpoint state.
6. If on a different git branch, inform the user: "Feature `<slug>` is on branch `{branch}`. Switch with: `git switch {branch}`". Do not switch branches for them.
7. Save state.

### `/workflow list-all`
Discover ALL features across the team — not just local ones. Scans committed artifacts and git branches.

**Steps:**
1. Fetch latest from all remotes: `git fetch --all` in each service dir.
2. Scan for features from multiple sources:
   - **PRDs:** `ls docs/prd/*.md` → extract slugs.
   - **Feature branches:** `git branch -r | grep -E '^(feature|fix|improvement)/[^/]*vc-'` in each service → extract slugs. Legacy `<worker>/vc-` branch names are accepted alongside `<prefix>vc-`.
   - **Worktrees:** `git worktree list` in each service dir plus sibling worktree dirs outside the workspace root.
   - **Track files:** `find . -name '*.track.md'` across all services → extract slugs.
3. For each unique slug found, reconstruct the phase from committed artifacts (same logic as resume):
   - Brainstorming summary recorded? PRD exists? Branch exists? Service PRDs? Track progress? PR?
4. Also check local `.workflow-state.json` for features only tracked locally.
5. Display a table:

```
All features (committed artifacts + local state):

  Slug                        Phase              Last Activity         Worker
  ─────────────────────────── ────────────────── ───────────────────── ──────────
→ brand-health-dashboard      implementation     2026-03-20 (track)    fahrizky
  user-analytics              pr_review          2026-03-18 (PR #42)   daffa
  kv-generator                prd_creation       2026-03-15 (PRD)      arhen

→ = active in your local .workflow-state.json
```

6. Mark reconstructed rows as artifact-derived, not authority. Show: "To pick up a feature: `/workflow resume <slug>`".

### `/workflow resume <slug>`
Resume a feature started by another team member.

**Steps:**
1. **Clear attention state first:** set `agent_state = null` and `agent_state_reason = null` on the feature entry, then continue.
2. Fetch latest: `git fetch --all` in each service dir.
3. Scan committed artifacts to reconstruct the phase:
   - Brainstorming summary recorded in `.workflow-state.json`? → past brainstorming.
   - PRD exists at `docs/prd/<slug>.md`? → past prd_creation.
   - Branch matching `(feature|fix|improvement)/vc-<slug>` (or legacy `<worker>/vc-<slug>`) exists AND service PRDs exist? → past prd_splitting.
   - Track files show progress? → in implementation.
   - PR URL in track file with no review threads? → in pr_submission (clean) or pr_review (has feedback).
   - PR merged? → in completion.
4. Read the latest session log from track files to show who last worked on it and what they did.
5. Create/update the feature entry with reconstructed **artifacts and phase**. Authority is different:
   - If the same feature entry already exists locally, keep a checkpoint field only when it records **verified explicit consent for this same task** (the user's wording is traceable in the track/session log). Persisted consent survives resume; do not re-ask it.
   - If the entry is being reconstructed from artifacts (no local entry), set `scope_approved: false`, `automation` both false, `execution_mode: null`, `implementation_approved: false`, `delivery: null`, `live_merge_approved: false`.
   - Never infer any of these from a PRD, track, branch, PR, or old session. A merged PR does not grant authority for a new delivery; an existing branch does not mean scope or implementation was approved now.
   - Never copy consent from another task or feature, and never treat a global/default preference as consent. Reconstructed features must re-confirm the pending checkpoint before crossing it.
   - Preserve the track's review-watch deadline and `rounds_used`; resume continues that budget rather than resetting it.
6. Set `active_feature` to `<slug>`.
7. Ask for the worker name if not already set.
8. Inform the user:
   - Reconstructed phase and which checkpoints are approved vs pending.
   - Last session log entry (who did what).
   - What's left to do (remaining tasks from track files).
   - Which branch to check out: `git switch <branch>` from `features[<slug>].branch` (prefix is `feature/`, `fix/`, or `improvement/` per type; legacy branch names are accepted as-is).
   - That the next checkpoint must be confirmed unless already recorded in this local state.

### `/workflow progress`
Show detailed progress for the active feature.

**Steps:**
1. Read `.workflow-state.json` and all related files.
2. Show:
   - Phase progression timeline with `phase_status` per phase.
   - Checkpoint table (Scope / Implementation / Delivery / Live merge).
   - Automation flags and resolved execution mode.
   - Brainstorming summary and decisions.
   - Service PRD status.
   - Track task completion, plan presence, verification evidence, and risk levels.
   - Review-watch status, deadline, rounds used, last head SHA.
   - PR self-review, security audit, adversarial review, and final review summaries.

### `/workflow worktrees`
Offer/parallelize work with git worktrees (see `/workflow start` step 4). One worktree per affected service repo, per feature; keyed by slug in `.workflow-state.json`; cleaned up at completion. No extra tooling — plain git.
