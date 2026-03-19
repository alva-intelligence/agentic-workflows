## Service Registry

### Services

| Service | Directory | Repository | Stack | Default Branch | Port |
|---------|-----------|-----------|-------|---------------|------|
| API | `api/` | alva-intelligence/frnd-api-php | Laravel 13, PHP 8.5, PostgreSQL, Sanctum + JWT | `develop` | 9191 |
| Frontend | `web/` | alva-intelligence/frnd-web | Next.js 16, React 19, TypeScript, Tailwind CSS, Zustand, TanStack Query v5, Bun | `develop` | 3000 |
| AI Service | `ai-service/` | alva-intelligence/frnd-ai-services | FastAPI, Python, Agno, OpenAI/Anthropic/Google, pgvector, Redis | `development` | 8000 |
| Data Service | `data-service/` | alva-intelligence/frnd-clickhouse-api | FastAPI, Python, pandas, Sentry | `development` | 9999 |

### Service Owners & Contacts

| Service | Owner | Contact |
|---------|-------|---------|
| API | arhen | arhen |
| Frontend | fahrizky, daffa | fahrizky, daffa |
| AI Service | rifki | rifki |
| Data Service | kemal, iru | kemal, iru |

### Start Commands (EXACT — do NOT guess)

| Service | Command | Working Directory | Entry Point |
|---------|---------|-------------------|-------------|
| API | `php artisan serve --port=9191` | `api/` | Laravel (artisan) |
| API Queue | `php artisan queue:work database --timeout=3000 --tries=5 --queue=high,low,default,subscriptions` | `api/` | Laravel queue worker |
| Frontend | `bun dev` | `web/` | Next.js dev server |
| AI Service | `source .venv/bin/activate && fastapi dev` | `ai-service/` | `main.py` via fastapi CLI |
| Data Service | `source .venv/bin/activate && uvicorn app.main:app --reload --port 9999` | `data-service/` | `app/main.py` (NOT `main:app`) |

**IMPORTANT:** The Data Service entry point is `app.main:app` (module `app/main.py`), NOT `main:app`. The AI Service uses `fastapi dev` (which reads from the project config), NOT `uvicorn main:app`.

### Health Check Endpoints (EXACT — do NOT guess)

| Service | Check Command | Healthy If |
|---------|--------------|-----------|
| API | `curl -so /dev/null -w "%{http_code}" http://localhost:9191/api` | Any HTTP response = running |
| Frontend | `curl -sf http://localhost:3000` | 200 OK |
| AI Service | `curl -sf http://localhost:8000/health` | 200 OK |
| Data Service | `curl -so /dev/null -w "%{http_code}" http://localhost:9999/api/v1/health/` | 200 OR 401 (401 = running but auth-protected) |
| PostgreSQL | `pg_isready -h localhost -p 5432` | exit 0 |
| Redis | `redis-cli ping` | "PONG" |

**IMPORTANT:**
- The API health check is at `/api`. Any HTTP response = running.
- The Data Service health endpoint is auth-protected. A **401 response means the service IS running** — treat it as healthy.
- Do NOT guess health endpoints — use the URLs above.

### Environment Files

| Service | Env File | Contact for Credentials |
|---------|---------|----------------------|
| API | `api/.env` | arhen |
| Frontend | `web/.env.local` | fahrizky, daffa |
| AI Service | `ai-service/.env` | rifki |
| Data Service | `data-service/.env` | kemal, iru |

### All Services

Use `./run-all.sh` from the workspace root to start all services concurrently.
Use `./run-all.sh --stop` to stop all running services.
Use `./run-all.sh --status` to check which services are running.

**Before starting services,** always check for port conflicts:
```bash
for port in 9191 3000 8000 9999; do
  pid=$(lsof -ti :$port 2>/dev/null)
  if [ -n "$pid" ]; then
    echo "⚠ Port $port in use by PID $pid — $(ps -p $pid -o comm= 2>/dev/null)"
  fi
done
```
Kill conflicting processes before starting, or the services will fail silently.
