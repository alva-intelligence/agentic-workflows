## Git Conventions

### Branch Naming

- Agent/vibe-coder branches: `<prefix>vc-<feature-slug>` (the `vc-` infix distinguishes agent-created branches from human-created ones)
- `<prefix>` is derived from `features[<slug>].type`:
  - `feature` → `feature/`
  - `bug` → `fix/`
  - `improvement` → `improvement/`
- Human branches: `<prefix><description>` (no `vc-` infix)
- Created from latest `develop` (for api, web, desktop) or `development` (for ai-service, data-service, data-pipeline)
- NEVER work directly on develop/development

### Branch Workflow

1. Ensure you're on the latest develop/development:
   ```bash
   git checkout develop && git pull origin develop
   ```
2. Resolve `<prefix>` from feature type (feature/ | fix/ | improvement/), then create the branch:
   ```bash
   git checkout -b <prefix>vc-<feature-slug>
   ```
   Feature work creates the branch during automatic preparation after scope approval.
   Bug/improvement work creates it at implementation entry, before implementation approval.
3. Make commits on the branch
4. Push to remote:
   ```bash
   git push -u origin <prefix>vc-<feature-slug>
   ```

### Commit Messages

Format: `<type>(<scope>): <description>`

Types:
- `feat` — New feature
- `fix` — Bug fix
- `docs` — Documentation only
- `refactor` — Code change that neither fixes a bug nor adds a feature
- `test` — Adding or updating tests
- `chore` — Maintenance tasks

Scope: the service or area affected (e.g., `api`, `web`, `ai`, `data`)

Examples:
- `feat(web): add brand health dashboard ui`
- `feat(api): add brand metrics endpoint`
- `docs(prd): create brand health dashboard PRD`

### PR Conventions

- **Title:** `feat(<service>): <feature> — <brief description>`
- **Body:** Include links to:
  - PRD (main + service) — only when a PRD exists (features); bugs/improvements skip PRDs
  - Track file
  - Self-review summary
  - Security audit summary (no high/critical findings)
- **Target branch:** `develop` (api, web) or `development` (ai-service, data-service, data-pipeline)
- **Review:** A human/repo owner reviews on the PR. The orchestrator may address feedback and
  resolve threads; re-request review only when the user says so.

### Delivery and Merge Authorization

Opening a PR and merging it are separate authorizations from the delivery checkpoint:

- **`local_test`** — the user manually tests locally first. No PR is opened, nothing is merged or
  published, and the branch/worktree/server stays available. The workflow remains pending at the
  delivery checkpoint until the user chooses `open_pr` or `auto_merge`; completion requires merged PRs.
- **`open_pr`** — open the PR(s) and stop before merge. Merging remains a human action.
- **`auto_merge`** — explicit per-task merge consent only. The orchestrator may merge only after the
  fail-closed conditions in `.agentic-workflows/workflow/gates.json` → `auto_merge_policy` pass on
  the latest head: full paginated thread inventory all resolved, required CI and configured expected
  review complete, approvals current with no changes requested and no conflicts, verification clean,
  branch protections respected, and the latest head SHA rechecked immediately before merge.

Rules:

- **Default merge is human.** Repository owners/humans review and merge. The orchestrator does not
  merge by default, and no global "owner-only" rule overrides explicit per-task `auto_merge` consent.
- `open_pr`, scope approval, implementation approval, and automation flags never authorize a merge.
- Never bypass, disable, or weaken branch protections; never force-push a shared branch; never push
  directly to `develop`/`development`/`main`.
- Every push invalidates prior head-specific proof; repeat the checks on the new head.
- A merge watch is bounded (default 30 minutes / 3 fix rounds; user may override). Persist progress,
  deadline, and rounds in the track; preserve them on resume. If the session cannot continue, pause
  as resumable — never claim background monitoring.
- **Merge strategy:** Squash merge.

> ⚠️ **data-pipeline: there is no deploy step — both branches are live Prefect estates.** The branch
> shape is the standard `development` → `main` every service uses; what differs is that a Prefect
> worker polls each estate and `git clone`s the branch **at run time**, so a merge is live the moment
> it lands — no build, no release step to forget. Target `development` for feature work; promotion to
> `main` is a deliberate, separate PR opened by a human, never part of a feature.
>
> `auto_merge` consent alone is insufficient for data-pipeline: `live_merge_approved` must be true for
> this task in addition to `delivery=auto_merge`. Both `development` and `main` are live; production
> promotion remains separate human work. Branch protections are never bypassed.
>
> The branch is pinned **per environment** by `scripts/register_paid_deployments.py` (`ENV_BRANCH`),
> not by `prefect.yaml` — that file has `deployments: []`, so its pull step is inert and its own
> comment says to leave it alone.
>
> Do not re-register Prefect deployments as a side effect of a feature. `data-service` triggers
> data-pipeline flows by **hardcoded deployment UUID** (`app/clients/prefect.py`), so a
> re-registration that mints a new id makes those calls 404 and the Fivetran-triggered pipeline stops
> — silently, since nothing on the data-pipeline side errors.

### Default Branches by Service

| Service | Repository | Default Branch |
|---------|-----------|---------------|
| API | alva-intelligence/frnd-api-php | `develop` |
| Frontend | alva-intelligence/frnd-web | `develop` |
| AI Service | alva-intelligence/frnd-ai-services | `development` |
| Data Service | alva-intelligence/frnd-clickhouse-api | `development` |
| Data Pipeline | alva-intelligence/frnd-orchestration | `development` |

### Rules

- Always pull and rebase before starting work
- Keep commits focused — one logical change per commit
- Don't commit `.env` files, secrets, or large binaries
- Don't force push to shared branches
- Never bypass branch protections or required review checks
