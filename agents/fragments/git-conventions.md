## Git Conventions

### Branch Naming

- Agent/vibe-coder branches: `feature/<worker>/vc-<feature-slug>` (the `vc-` prefix distinguishes agent-created branches from human-created ones)
- Human branches: `feature/<description>` (no prefix)
- Created from latest `develop` (for api, web) or `development` (for ai-service, data-service)
- NEVER work directly on develop/development

### Branch Workflow

1. Ensure you're on the latest develop/development:
   ```bash
   git checkout develop && git pull origin develop
   ```
2. Create the feature branch:
   ```bash
   git checkout -b feature/<worker>/vc-<feature-slug>
   ```
3. Make commits on the feature branch
4. Push to remote:
   ```bash
   git push -u origin feature/<worker>/vc-<feature-slug>
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
- `feat(web): add brand health dashboard wireframe`
- `feat(api): add brand metrics endpoint`
- `docs(prd): create brand health dashboard PRD`

### PR Conventions

- **Title:** `feat(<service>): <feature> — <brief description>`
- **Body:** Must include links to:
  - PRD (main + service)
  - Wireframe (if applicable)
  - Track file
- **Target branch:** `develop` (api, web) or `development` (ai-service, data-service)
- **Merge strategy:** Squash merge by repo owner
- **Review:** Repo owner reviews and merges

### Default Branches by Service

| Service | Repository | Default Branch |
|---------|-----------|---------------|
| API | alva-intelligence/frnd-api-php | `develop` |
| Frontend | alva-intelligence/frnd-web | `develop` |
| AI Service | alva-intelligence/frnd-ai-services | `development` |
| Data Service | alva-intelligence/frnd-clickhouse-api | `development` |

### Rules

- Always pull and rebase before starting work
- Keep commits focused — one logical change per commit
- Don't commit `.env` files, secrets, or large binaries
- Don't force push to shared branches
