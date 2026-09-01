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
| API | `php artisan optimize:clear && php artisan optimize && php artisan serve --port=9191` | `api/` | Laravel (artisan) |
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
| ClickHouse | `curl -s localhost:8123 --data-binary "SELECT 1"` | prints `1` |

**IMPORTANT:**
- The API health check is at `/api`. Any HTTP response = running.
- The Data Service health endpoint is auth-protected. A **401 response means the service IS running** — treat it as healthy.
- Do NOT guess health endpoints — use the URLs above.
- ClickHouse answers over **HTTP on 8123** (plain HTTP locally, no TLS). Port 8443 is the ClickHouse **Cloud** port and is the code default in `data-service/app/core/config.py` — a local `.env` must set `CH_PORT=8123` or the connection fails even with `CH_HOST=localhost`.

### Backing Services

ClickHouse is a **backing service**, like PostgreSQL and Redis: a shared
singleton that `run-all.sh` neither starts nor stops. It is provisioned by the
Nix flake (`clickhouse` in `buildInputs`) and its local lifecycle — start the
server, create the databases and the `frndos_data_service` user, apply the
migrations, seed the demo — is owned by one script:

```bash
bash data-service/scripts/setup-local-demo.sh
```

That script is idempotent and safe to re-run. It downloads a standalone
ClickHouse binary into `$CH_LOCAL_DIR` (default `$HOME/clickhouse-local`) when
one is not already on PATH, so it works whether or not you are inside
`nix develop`.

**Local ClickHouse is the default, not an opt-in.** A new developer should never
be given the staging host to get started; `data-service/.env.example` ships
pointing at `localhost:8123`. Staging is the thing you opt into, by replacing the
`CH_*` values and setting `APP_ENV=staging`.

| Local credential | Value | Set by |
|---|---|---|
| `CH_HOST` / `CH_PORT` | `localhost` / `8123` | `data-service/.env.example` |
| `CH_USER` / `CH_PASSWORD` | `frndos_data_service` / `demo_local_pw` | created by `setup-local-demo.sh` |
| `CH_DATABASE` | `frnd_agg_marts` | `data-service/.env.example` |

**Windows:** Nix does not run natively on Windows, so `nix develop` is not the
path there — use WSL2 and follow the Linux instructions, or run
`setup-local-demo.sh`'s standalone binary directly. There is no Docker Compose
path for ClickHouse in this workspace; it was considered and dropped (decisions
ledger `W13a`, and `docs/prd/local-pipeline-e2e.workspace-root.md` FR-26).

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
