## Service Registry

### Services

| Service | Directory | Repository | Stack | Default Branch | Port |
|---------|-----------|-----------|-------|---------------|------|
| API | `api/` | alva-intelligence/frnd-api-php | Laravel 12, PHP 8.2+, PostgreSQL, Sanctum + JWT | `develop` | 9191 |
| Frontend | `web/` | alva-intelligence/frnd-web | Next.js 16, React 19, TypeScript, Tailwind CSS, Zustand, TanStack Query v5, Bun | `develop` | 3000 |
| AI Service | `ai-service/` | alva-intelligence/frnd-ai-services | FastAPI, Python, Agno, OpenAI/Anthropic/Google, pgvector, Redis | `development` | 8000 |
| Data Service | `data-service/` | alva-intelligence/frnd-clickhouse-api | FastAPI, Python, ClickHouse, pandas, Sentry | `development` | 9999 |

### Service Owners & Contacts

| Service | Owner | Contact |
|---------|-------|---------|
| API | arhen | arhen |
| Frontend | fahrizky, daffa | fahrizky, daffa |
| AI Service | rifki | rifki |
| Data Service | kemal, iru | kemal, iru |

### Health Check Endpoints

| Service | URL | Expected |
|---------|-----|----------|
| API | http://localhost:9191/health | 200 OK |
| Frontend | http://localhost:3000 | 200 OK |
| AI Service | http://localhost:8000/health | 200 OK |
| Data Service | http://localhost:9999/health | 200 OK |
| PostgreSQL | `pg_isready -h localhost -p 5432` | exit 0 |
| ClickHouse | http://localhost:8123/ping | "Ok." |
| Redis | `redis-cli ping` | "PONG" |

### Environment Files

| Service | Env File | Contact for Credentials |
|---------|---------|----------------------|
| API | `api/.env` | arhen |
| Frontend | `web/.env.local` | fahrizky, daffa |
| AI Service | `ai-service/.env` | rifki |
| Data Service | `data-service/.env` | kemal, iru |

### Start Commands

| Service | Command | Working Directory |
|---------|---------|-------------------|
| API | `php artisan serve --port=9191` | `api/` |
| Frontend | `bun dev` | `web/` |
| AI Service | `uvicorn main:app --port=8000 --reload` | `ai-service/` |
| Data Service | `uvicorn main:app --port=9999 --reload` | `data-service/` |

### All Services

Use `./run-all.sh` from the workspace root to start all services concurrently.
Use `./run-all.sh --stop` to stop all running services.
Use `./run-all.sh --status` to check which services are running.
