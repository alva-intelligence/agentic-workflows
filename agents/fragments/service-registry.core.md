## Services (quick reference)

| Service | Dir | Port | Default Branch | Start |
|---------|-----|------|---------------|-------|
| API | `api/` | 9191 | `develop` | `php artisan serve --port=9191` |
| Frontend | `web/` | 3000 | `develop` | `bun dev` |
| AI Service | `ai-service/` | 8000 | `development` | `fastapi dev` |
| Data Service | `data-service/` | 9999 | `development` | `uvicorn app.main:app --reload --port 9999` |
| Orchestration | `orchestration/` | — | `development` | no long-running server (local Prefect `:4200` is opt-in) |

> ⚠️ **`orchestration/` is the transform layer.** Its branch model is the standard one, but two
> things differ from every other service. **(1) No port, no server:** it runs no long-lived process
> and is absent from `run-all.sh` by design, so there is nothing to start and nothing to
> health-check. **(2) No deploy step:** a Prefect worker polls each estate and clones the branch at
> run time, so a merge is live the moment it lands. It also has **no `.env`** — credentials are
> Prefect Secret blocks, so its `env_status` is `"n/a"`, which satisfies the onboarding gate. Full
> rules: `orchestration/AGENTS.md`.

Full registry (owners, env files, exact start/health commands, port-conflict check): `skills/onboard/references/service-registry.md`.
