## Git Conventions

### Branch Naming

- Agent/vibe-coder branches: `<prefix><worker>/vc-<feature-slug>` (the `vc-` infix distinguishes agent-created branches from human-created ones)
- `<prefix>` is derived from `features[<slug>].type`:
  - `feature` → `feature/`
  - `bug` → `fix/`
  - `improvement` → `improvement/`
- Human branches: `<prefix><description>` (no `vc-` infix)
- Created from latest `develop` (for api, web), `development` (for ai-service, data-service), or `staging` (for orchestration)
- NEVER work directly on a base branch — `develop`, `development`, `staging`, **or `main`**.
  Orchestration's base is `staging` (which its staging deployments pull) and `main` is its
  production branch, so a direct commit to either one ships.

### Branch Workflow

1. Ensure you're on the latest develop/development:
   ```bash
   git checkout develop && git pull origin develop
   ```
2. Resolve `<prefix>` from feature type (feature/ | fix/ | improvement/), then create the branch:
   ```bash
   git checkout -b <prefix><worker>/vc-<feature-slug>
   ```
3. Make commits on the branch
4. Push to remote:
   ```bash
   git push -u origin <prefix><worker>/vc-<feature-slug>
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
- **Body:** Must include links to:
  - PRD (main + service)
  - Track file
  - Self-review summary
  - Security audit summary
- **Target branch:** `develop` (api, web), `development` (ai-service, data-service), or `staging` (orchestration)
- **Merge strategy:** Squash merge by repo owner
- **Review:** Repo owner reviews and merges

### Default Branches by Service

| Service | Repository | Default Branch |
|---------|-----------|---------------|
| API | alva-intelligence/frnd-api-php | `develop` |
| Frontend | alva-intelligence/frnd-web | `develop` |
| AI Service | alva-intelligence/frnd-ai-services | `development` |
| Data Service | alva-intelligence/frnd-clickhouse-api | `development` |
| Orchestration | alva-intelligence/frnd-orchestration | `staging` (work) · `main` (production) |

> ⚠️ **orchestration is staging-first.** Deployments are registered **per environment** on one
> shared server (`prefect.frndos.com`): **staging** pulls the `staging` branch (pool `staging-pool`,
> queue `ads-staging`); **production** pulls `main` (pool `local-pool`, queue `ads`). Both pools
> report `READY` with a live worker — verified on the estate 2026-08-27.
>
> **Feature work branches from `staging` and PRs into `staging`.** Reaching production is a
> **separate promotion PR, `staging` → `main`**, opened deliberately by a human — never as part of a
> feature. As of 2026-08-27 `main` is a strict ancestor of `staging` (43 behind, 0 ahead), so the
> promotion is a clean merge and nothing needs rebasing.
>
> Open the PR and stop — never merge it yourself, never push to `staging` or `main`. Deployment ids
> for `webhook-sync` / `webhook-delete` are frozen: data-service triggers them **by id** (hard rule
> 13).
>
> ⚠️ `orchestration/AGENTS.md` hard rule 1 still reads *"`main` deploys to staging AND production at
> once"*. That was true before staging went live and is now stale. It is a different repo and is not
> corrected here — believe the estate, not the rule text.

### Promoting orchestration to production

A merge into `staging` reaches the staging estate only. Production is reached by a **separate PR
from `staging` into `main`**, and that PR is a deliberate release decision, not a step in a feature:

1. Confirm what is being released: `git log --oneline origin/main..origin/staging`.
2. Open the promotion PR `staging` → `main`. Title it as a release, not a feature.
3. A human reviews and merges it. **An agent never opens, approves or merges a promotion PR
   unasked** — ask first, every time.

`post-merge.yml` in that repo has its `promote` job **dropped**, so nothing automates this.
>
>
> Deployment ids for `webhook-sync` / `webhook-delete` are frozen: data-service triggers them **by id** (hard rule 13).

### Rules

- Always pull and rebase before starting work
- Keep commits focused — one logical change per commit
- Don't commit `.env` files, secrets, or large binaries
- Don't force push to shared branches
