## Services (quick reference)

| Service | Dir | Port | Default Branch | Start |
|---------|-----|------|---------------|-------|
| API | `api/` | 9191 | `develop` | `php artisan serve --port=9191` |
| Frontend | `web/` | 3000 | `develop` | `bun dev` |
| AI Service | `ai-service/` | 8000 | `development` | `fastapi dev` |
| Data Service | `data-service/` | 9999 | `development` | `uvicorn app.main:app --reload --port 9999` |

Full registry (owners, env files, exact start/health commands, port-conflict check): `skills/onboard/references/service-registry.md`.
