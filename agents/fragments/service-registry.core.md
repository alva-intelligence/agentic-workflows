## Services (quick reference)

| Service | Dir | Port | Default Branch | Start |
|---------|-----|------|---------------|-------|
| API | `api/` | 9191 | `develop` | `php artisan serve --port=9191` |
| Frontend | `web/` | 3000 | `develop` | `bun dev` |
| AI Service | `ai-service/` | 8000 | `development` | `fastapi dev` |
| Data Service | `data-service/` | 9999 | `development` | `uvicorn app.main:app --reload --port 9999` |
| Orchestration | `orchestration/` | — | `staging` ¹ | no long-running server (Prefect `:4200` is opt-in) |

¹ Work branches from and PRs into `staging`. The repo's *default* branch is still `main`, which is production — see the warning below.

> ⚠️ **`orchestration/` is the transform layer between Fivetran's raw tables and the marts
> data-service serves.** It claims no port and is absent from `run-all.sh` by design.
> Verified on the estate 2026-08-27: **production** deployments pull `main` (pool `local-pool`, queue `ads`); **staging** deployments pull `staging` (pool `staging-pool`, queue `ads-staging`, tag `branch:staging`), and both pools report `READY`, meaning a live worker is polling each. So a merge to `main` reaches **production**.
>
> **Feature work branches from `staging` and PRs into `staging`.** Reaching production is a **separate promotion PR, `staging` → `main`**, opened deliberately by a human — never as part of a feature. `main` is a strict ancestor of `staging` (43 behind, 0 ahead as of 2026-08-27), so the promotion is a clean merge. Open the PR and stop either way: never merge it yourself, never push to `staging` or `main`.
>
> Prefect estate rules, the 18 hard rules and the cross-repo contracts live in
> `orchestration/AGENTS.md`; the plain-language tour is `orchestration/docs/START-HERE.md`.

Full registry (owners, env files, exact start/health commands, port-conflict check): `skills/onboard/references/service-registry.md`.
