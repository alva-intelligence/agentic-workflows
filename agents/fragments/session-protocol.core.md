## SESSION START PROTOCOL (MANDATORY)

**This protocol MUST be executed before ANY other work. No exceptions.**

### Step 0: Detect workspace state

1. **No service directories** (none of `api/`, `web/`, `ai-service/`, `data-service/`,
   `data-pipeline/`, `desktop/`, `hocuspocus/` exist) → Fresh workspace. Ask: "This workspace hasn't been set up
   yet. Would you like to start onboarding now?" On yes, execute `skills/onboard/SKILL.md`
   directly. On no, tell the user they can run `/onboard` later.
2. **`.onboard-state.json` exists and `status` is `"in_progress"`** → Check `env_status`,
   `steps.db_setup`; if critical items are missing, tell the user to run `/onboard resume` or
   `/onboard verify`. Block workflow commands until resolved. **`env_status` of `"n/a"` counts as
   resolved, not missing** — no `.env` by design (data-pipeline uses Prefect Secret blocks). Only
   `"pending"` blocks.
3. **`.onboard-state.json` completed (or absent with services present)** → Proceed. If
   `.workflow-state.json` is missing, welcome the user and point at
   `/workflow start <feature-slug>`, `/workflow list`.
4. **`.workflow-state.json` exists** → Proceed through the remaining steps.

### Service dependencies: Hocuspocus, data-pipeline and desktop

`hocuspocus/` (frnd-hocuspocus — shared Yjs editing and presence) is included by default for
web/full-stack onboarding, but may be explicitly skipped for unrelated setups. `data-pipeline/`
(frnd-orchestration — Prefect flows) and `desktop/` (frnd-desktop — native macOS app) are optional.
When the user's request needs their capabilities:

- Live Decks, Docs, KV or Studio editing, collaboration/persistence checks, or proposal/Insights/
  Market presence → needs Hocuspocus configured with the API and its Postgres. A page rendering
  without a collab connection is not evidence that edits persist. Require the repo for collab
  service changes; an explicitly configured remote service is not permission to change a live estate.
- Data orchestration/flow/pipeline work → needs `data-pipeline/`; native desktop-app work →
  needs `desktop/`.
- If the directory is **absent**, stop and recommend onboarding it first (execute the matching
  onboarding path in `skills/onboard/SKILL.md` when the user agrees). Do not silently skip a
  service the request clearly needs.
- If the user's request doesn't touch them, they stay out of the way.

### Step 1: Check for instruction updates + sync

Run the update-check script and sync the current branch. Detailed procedure (including dependency
bootstraps and conflict handling): `skills/workflow/references/session-checks.md` →
"Update check + sync". After updating, review `.agentic-workflows/workflow/model-catalog.json`
using the model-catalog procedure in the workflow rules. Review on first use or a changed catalog
digest, notify the user once, and acknowledge only after the review completes. Preserve explicit
model/provider choices; unavailable recommendations are not permission to invent model IDs or
silently switch the running main model. Unchanged catalogs do not repeat the notice.

### Step 2: Load workflow state

Read `.workflow-state.json` to determine:

- Which feature is currently active (`active_feature`)
- What phase it's in (`features[active_feature].phase`)
- Its `phase_status` and `worker`
- Checkpoint state: `scope_approved`, `implementation_approved`, `delivery`,
  `live_merge_approved`
- Pre-authorizations: `automation.brainstorming`, `automation.implementation`
- Resolved execution mode: `execution_mode`
- Plan/verification evidence: `verification`

Absent fields mean false/null (safe defaults) — absence is never approval. If
`.workflow-state.json` doesn't exist, no features are active yet.

### Step 3: Feature branch recency + service health

After pulling, if any service is on a feature branch, run the recency check against its base
branch. Then verify that required services are healthy. Full procedures: the same
`references/session-checks.md`.

### Step 4: Drive the phase as the orchestrator — checkpoint first

Before doing phase work, determine whether a human checkpoint is pending:

- `phase == "brainstorming"` and `scope_approved !== true` → scope checkpoint.
- `phase == "implementation"` and `implementation_approved !== true` and
  `automation.implementation !== true` → implementation checkpoint.
- `phase == "pr_submission"` and `delivery` is null → delivery checkpoint.

If a checkpoint is pending, surface it and stop. Do not run work behind a checkpoint.

**Scope.** Run brainstorming (skill `brainstorm`). With `automation.brainstorming=true`, record the
recommended/chosen directions and summary, set `scope_approved=true`, and continue without asking
again. An explicit "skip brainstorming" counts as scope approval (record `user_skipped`). Scope
approval authorizes preparation only.

**After scope approval — automatic preparation.** Do not ask per document and do not require
`/workflow next`:

- Feature: run `prd_creation` → `prd_splitting` automatically — main PRD, branch, per-service PRDs,
  tracks, plans. `prd_creation` and `prd_splitting` are the only automatic-advance phases.
- Bug/improvement: skip the PRD phases; prepare the branch and plans at implementation entry.

Preparation stops at the implementation checkpoint. `phase_status: completed` records that artifacts
are ready; it is not approval to write code.

**Implementation.** Present the prepared branch/plans. Unless `automation.implementation=true`, ask
once and set `implementation_approved=true` on approval. No code before. Resolve `execution_mode`
(feature/improvement → subagents; bug/hotfix → main; trivial/coupled → main; complex bug may
recommend subagents; user override wins). Then implement, verify independently, reconcile TODO, and
advance to the delivery checkpoint.

**Delivery.** After independent verification, ask once for `local_test`, `open_pr`, or `auto_merge`
and record `delivery`. Null fails closed: no PR, no merge, no publication. `local_test` means the
user manually tests locally first — open no PR, keep the branch/worktree/server available, and stay
pending at the delivery checkpoint; it is not completion. `open_pr` opens but never merges;
`auto_merge` is a separate per-task merge opt-in with the checks in
`.agentic-workflows/workflow/gates.json` → `auto_merge_policy`. Completion requires the intended PRs
to be merged. Persisted consent for the same task may survive resume; never infer it from artifacts
or copy it from another task. A new task/scope/target invalidates prior merge consent. For
data-pipeline, `live_merge_approved` is required in addition; production promotion remains separate
human work.

**Resume.** Reconstruct the phase from committed artifacts, clear `agent_state`, and present any
pending checkpoint. Do not reset a preserved watch deadline or fix-round count. Never infer consent
from artifacts; ask only for the pending checkpoint, and do not repeat decisions whose verified
persisted consent still applies to the same task.
