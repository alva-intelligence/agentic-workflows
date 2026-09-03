## Service Registry

### Services

| Service | Directory | Repository | Stack | Default Branch | Port |
|---------|-----------|-----------|-------|---------------|------|
| API | `api/` | alva-intelligence/frnd-api-php | Laravel 13, PHP 8.5, PostgreSQL, Sanctum + JWT | `develop` | 9191 |
| Frontend | `web/` | alva-intelligence/frnd-web | Next.js 16, React 19, TypeScript, Tailwind CSS, Zustand, TanStack Query v5, Bun | `develop` | 3000 |
| AI Service | `ai-service/` | alva-intelligence/frnd-ai-services | FastAPI, Python, Agno, OpenAI/Anthropic/Google, pgvector, Redis | `development` | 8000 |
| Data Service | `data-service/` | alva-intelligence/frnd-clickhouse-api | FastAPI, Python, pandas, Sentry | `development` | 9999 |
| Orchestration | `orchestration/` | alva-intelligence/frnd-orchestration | Prefect 3, Python 3.12, ClickHouse, AWS S3 | `development` | — (no server) |

> ⚠️ **`orchestration/` breaks two assumptions the other four services share.**
> 1. **No port, no server.** It runs no long-lived process and is absent from `run-all.sh` by design.
>    A local Prefect server on `:4200` is opt-in (onboard Step 7.5) and only needed for flow
>    development. There is nothing to health-check.
> 2. **There is no deploy step — both branches are live estates.** The branch shape matches
>    ai-service and data-service (`development` for work, `main` for production), but a Prefect worker
>    polls each estate and `git clone`s the branch **at run time**. So a merge to `development` is
>    live on staging and a merge to `main` is live in production, immediately — there is no build or
>    release to forget. Feature work branches from and PRs into `development`; production is a
>    deliberate `development` → `main` promotion PR opened by a human. Open PRs; never merge them
>    yourself, never push directly to either branch.

### Service Owners & Contacts

| Service | Owner | Contact |
|---------|-------|---------|
| API | arhen | arhen |
| Frontend | fahrizky, daffa | fahrizky, daffa |
| AI Service | rifki | rifki |
| Data Service | fahmi, arhen | fahmi, arhen |
| Orchestration | fahmi (data engineer) | fahmi |

> **Fivetran and connector changes are NOT part of a normal code change.** Enabling, pausing or
> re-scheduling a connector costs money on someone else's budget. Connectors land the `raw_*` tables
> that orchestration transforms, so a change there is owned jointly by **fahmi and arhen** (the
> data-service PICs) — raise it as its own request, never as a side effect of a metric change.
>
> **Orchestration itself is fahmi's.** The transform layer, its Prefect estate and its Secret blocks
> have a single PIC; the joint ownership above applies to the Fivetran/connector boundary feeding it.

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
| Data Service | `data-service/.env` | fahmi, arhen |
| Orchestration | **none** — Prefect Secret blocks | fahmi |

> **Orchestration has no `.env`.** Its runtime credentials are Prefect Secret blocks fetched from the
> server at flow time, so its `env_status` in `.onboard-state.json` is the literal string `"n/a"` —
> and `"n/a"` **satisfies** the `env_files` gate. A strict `== "completed"` check would block
> `/workflow start` forever for anyone who selects it. Setup: onboard Steps 6b and 7.5.

### All Services

Use `./run-all.sh` from the workspace root to start all services concurrently.
Use `./run-all.sh --stop` to stop all running services.
Use `./run-all.sh --status` to check which services are running.

**Before starting services,** always check for port conflicts:
```bash
for port in 9191 3000 8000 9999 8123 4200; do
  pid=$(lsof -ti :$port 2>/dev/null)
  if [ -n "$pid" ]; then
    echo "⚠ Port $port in use by PID $pid — $(ps -p $pid -o comm= 2>/dev/null)"
  fi
done
```
Kill conflicting processes before starting, or the services will fail silently.

> ⚠️ **`8123` and `4200` are exceptions — never kill them.** They are the local ClickHouse server and
> the local Prefect server, which the developer was asked to leave running in their own terminals
> (onboard Steps 7.4.2 and 7.5.2). Neither is started or stopped by `run-all.sh`. Killing ClickHouse
> drops the local cluster every mart lives in. In-use on those two ports is **expected**, not a conflict.
