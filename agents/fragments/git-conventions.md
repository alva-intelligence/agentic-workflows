## Git Conventions

### Branch Naming

- Agent/vibe-coder branches: `<prefix><worker>/vc-<feature-slug>` (the `vc-` infix distinguishes agent-created branches from human-created ones)
- `<prefix>` is derived from `features[<slug>].type`:
  - `feature` → `feature/`
  - `bug` → `fix/`
  - `improvement` → `improvement/`
- Human branches: `<prefix><description>` (no `vc-` infix)
- Created from latest `develop` (for api, web) or `development` (for ai-service, data-service, orchestration)
- NEVER work directly on develop/development

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
- **Target branch:** `develop` (api, web) or `development` (ai-service, data-service, orchestration)

> ⚠️ **orchestration: there is no deploy step — both branches are live Prefect estates.** The branch
> shape is the standard `development` → `main` every service uses; what differs is that a Prefect
> worker polls each estate and `git clone`s the branch **at run time**, so a merge is live the moment
> it lands — no build, no release step to forget. Target `development` for feature work; promotion to
> `main` is a deliberate, separate PR opened by a human, never part of a feature. Open the PR and
> stop: never merge it yourself, never push directly to either branch.
>
> The branch is pinned **per environment** by `scripts/register_paid_deployments.py` (`ENV_BRANCH`),
> not by `prefect.yaml` — that file has `deployments: []`, so its pull step is inert and its own
> comment says to leave it alone.
>
> Do not re-register Prefect deployments as a side effect of a feature. `data-service` triggers
> orchestration flows by **hardcoded deployment UUID** (`app/clients/prefect.py`), so a
> re-registration that mints a new id makes those calls 404 and the Fivetran-triggered pipeline stops
> — silently, since nothing on the orchestration side errors.
- **Merge strategy:** Squash merge by repo owner
- **Review:** Repo owner reviews and merges

### Default Branches by Service

| Service | Repository | Default Branch |
|---------|-----------|---------------|
| API | alva-intelligence/frnd-api-php | `develop` |
| Frontend | alva-intelligence/frnd-web | `develop` |
| AI Service | alva-intelligence/frnd-ai-services | `development` |
| Data Service | alva-intelligence/frnd-clickhouse-api | `development` |
| Orchestration | alva-intelligence/frnd-orchestration | `development` |

### Rules

- Always pull and rebase before starting work
- Keep commits focused — one logical change per commit
- Don't commit `.env` files, secrets, or large binaries
- Don't force push to shared branches
