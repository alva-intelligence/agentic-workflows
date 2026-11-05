## Service Registry

### Services

| Service | Directory | Repository | Stack | Default Branch | Port |
|---------|-----------|-----------|-------|---------------|------|
| API | `api/` | alva-intelligence/frnd-api-php | Laravel 13, PHP 8.5, PostgreSQL, Sanctum + JWT | `develop` | **9191** + pg `:5432` |
| Frontend | `web/` | alva-intelligence/frnd-web | Next.js 16, React 19, TypeScript, Tailwind CSS, Zustand, TanStack Query v5, Bun | `develop` | **3000** |
| AI Service | `ai-service/` | alva-intelligence/frnd-ai-services | FastAPI, Python, Agno, OpenAI/Anthropic/Google, pgvector, Redis | `development` | **8000** + pg `:5432`, redis `:6379` |
| Data Service | `data-service/` | alva-intelligence/frnd-clickhouse-api | FastAPI, Python, pandas, Sentry | `development` | **9999** + ch `:8123`, prefect `:4200` |
| Data Pipeline | `data-pipeline/` | alva-intelligence/frnd-orchestration | Prefect 3, Python 3.12, ClickHouse, AWS S3 | `development` | prefect `:4200` + ch `:8123` |
| Hocuspocus | `hocuspocus/` | alva-intelligence/frnd-hocuspocus | Node 20.12+, TypeScript, Yjs, Hocuspocus server, tsx | `main` | **1234** + API pg `:5432` |

> **Bold = the port the service itself serves on. Unbolded = a backing service it connects to.**
> Only the bold ones are `run-all.sh`'s to start, health-check or stop; Postgres `:5432`, Redis
> `:6379`, ClickHouse `:8123` and Prefect `:4200` are shared infrastructure the developer runs, and
> the template reports them without ever killing them (`SHARED_PORTS`).
>
> Ports are the local defaults, read from each repo's `.env` / `.env.example` on 2026-09-07. Two
> corrections worth carrying: **API does not use Redis locally** — `.env.example` ships `REDIS_*`,
> but `QUEUE_CONNECTION=database` and `CACHE_STORE=file`, so nothing connects to `:6379`; and
> **Data Service talks to Prefect too** (`PREFECT_API_URL=http://127.0.0.1:4200/api`), which is easy
> to miss because Prefect reads as a data-pipeline concern.

> ⚠️ **`data-pipeline/` breaks two assumptions the other four services share.**
> 1. **No port of its own.** It runs no long-lived process and is absent from `run-all.sh` by design.
>    Its Port cell lists what its flows *connect to*, not what it serves: the local Prefect server on
>    `:4200` (onboarding Step 7.5, required for anyone who picked Data Pipeline) and local ClickHouse
>    on `:8123` (Step 7.4.2). You start both by hand when you work on flows, so `run-all.sh` has
>    nothing to launch and nothing to health-check here.
>    It is also the only service with **no `.env`** — every credential comes from Prefect Secret
>    blocks (7.5.3), which is why there is no file to point at a port.
> 2. **There is no deploy step — both branches are live estates.** The branch shape is the standard
>    one (`development` for work, `main` for release), but a Prefect worker polls each estate and
>    `git clone`s the branch **at run time**. So a merge is live the moment it lands — there is no
>    build or release to forget. Feature work branches from and PRs into `development`; merging there
>    needs a separate, explicit, task-specific live-estate approval in addition to the task's
>    `auto_merge` choice — without it, open the PR and stop. Promotion to `main` is a separate,
>    human-only PR. Never open or merge promotion, and never push directly to either branch.

> ⚠️ **`hocuspocus/` is the collaboration server and differs in four ways.** Values below were verified
> against `alva-intelligence/frnd-hocuspocus` `main` at `0df71ea1d6c7ff19e94be7991c3bbd7f8fffb2de`;
> re-verify rather than trusting this table when the repo moves.
> 1. **`main` is its working base.** Unlike api/web (`develop`) and the data services
>    (`development`), hocuspocus branches from and PRs into `main`. The `vc-` branch rule, the
>    delivery checkpoint, branch protections and the no-direct-push rule all still apply — `main`
>    being the base grants no merge authority.
> 2. **No migrations and no database of its own.** Yjs updates are written to the API's already
>    migrated PostgreSQL through `DATABASE_URL`. Run migrations in `api/` only; hocuspocus has no
>    migration runner and no schema to apply.
> 3. **Node ≥ 20.12 is a hard floor**, because `src/config.ts` calls `loadEnvFile`. The package's own
>    `engines` field says 20, which is understated. Onboarding's Node 22 pin satisfies it — do not
>    lower it for hocuspocus.
> 4. **`GET /health` on :1234 is the only health surface.** `PORT` and the timeout settings remain
>    configurable in `hocuspocus/.env`; a non-default `PORT` is a configuration choice, not a fault.
>
> **Room types worth knowing before debugging sync.** Persisted in Postgres: bare deck ID,
> `kv_file:<id>`, `doc:<id>`, `studio:<id>`. Presence-only (dropping them loses nothing):
> `proposal:`, `insight:`, `market:`. Report the first group as the collaboration surface; never claim
> the second group persists.
>
> At the verified revision no repo-local `AGENTS.md`/`CLAUDE.md` existed. Check after cloning or
> updating and read any instructions added since; this observation never overrides repo-local rules.

### Service Owners & Contacts

| Service | Owner | Contact |
|---------|-------|---------|
| API | arhen | arhen |
| Frontend | fahrizky, daffa | fahrizky, daffa |
| AI Service | rifki | rifki |
| Data Service | fahmi, arhen | fahmi, arhen |
| Data Pipeline | fahmi (data engineer) | fahmi |
| Hocuspocus | not recorded — confirm with the team | API/collaboration maintainer |

> **Fivetran and connector changes are NOT part of a normal code change.** Enabling, pausing or
> re-scheduling a connector costs money on someone else's budget. Connectors land the `raw_*` tables
> that data-pipeline transforms, so a change there is owned jointly by **fahmi and arhen** (the
> data-service PICs) — raise it as its own request, never as a side effect of a metric change.
>
> **Data Pipeline itself is fahmi's.** The transform layer, its Prefect estate and its Secret blocks
> have a single PIC; the joint ownership above applies to the Fivetran/connector boundary feeding it.

### Start Commands (EXACT — do NOT guess)

| Service | Command | Working Directory | Entry Point |
|---------|---------|-------------------|-------------|
| API | `php artisan optimize:clear && php artisan optimize && php artisan serve --port=9191` | `api/` | Laravel (artisan) |
| API Queue | `php artisan queue:work database --timeout=3000 --tries=5 --queue=high,low,default,subscriptions` | `api/` | Laravel queue worker |
| Frontend | `bun dev` | `web/` | Next.js dev server |
| AI Service | `source .venv/bin/activate && fastapi dev` | `ai-service/` | `main.py` via fastapi CLI |
| Data Service | `source .venv/bin/activate && uvicorn app.main:app --reload --port 9999` | `data-service/` | `app/main.py` (NOT `main:app`) |
| Hocuspocus | `npm run dev` (after setup's `npm ci`) | `hocuspocus/` | `src/index.ts` via `tsx watch` |

**IMPORTANT:** The Data Service entry point is `app.main:app` (module `app/main.py`), NOT `main:app`. The AI Service uses `fastapi dev` (which reads from the project config), NOT `uvicorn main:app`.

### Health Check Endpoints (EXACT — do NOT guess)

| Service | Check Command | Healthy If |
|---------|--------------|-----------|
| API | `curl -so /dev/null -w "%{http_code}" http://localhost:9191/api` | Any HTTP response = running |
| Frontend | `curl -sf http://localhost:3000` | 200 OK |
| AI Service | `curl -sf http://localhost:8000/health` | 200 OK |
| Data Service | `curl -so /dev/null -w "%{http_code}" http://localhost:9999/api/v1/health/` | 200 OR 401 (401 = running but auth-protected) |
| Hocuspocus | `curl -sf http://localhost:1234/health` | 200 OK (respect a custom `PORT` in `hocuspocus/.env`) |
| PostgreSQL | `pg_isready -h localhost -p 5432` | exit 0 |
| Redis | `redis-cli ping` | "PONG" |

**IMPORTANT:**
- The API health check is at `/api`. Any HTTP response = running.
- The Data Service health endpoint is auth-protected. A **401 response means the service IS running** — treat it as healthy.
- Do NOT guess health endpoints — use the URLs above.
- Hocuspocus serves a WebSocket endpoint on the same port as `/health`. A 200 from `/health` proves
  the process and its config loaded; it does **not** prove two clients sync. Never substitute it for
  a real edit-in-one-client/reload-in-another check.

### Environment Files

| Service | Env File | Contact for Credentials |
|---------|---------|----------------------|
| API | `api/.env` | arhen |
| Frontend | `web/.env.local` | fahrizky, daffa |
| AI Service | `ai-service/.env` | rifki |
| Data Service | `data-service/.env` | fahmi, arhen |
| Data Pipeline | **none** — Prefect Secret blocks | fahmi |
| Hocuspocus | `hocuspocus/.env` | API/collaboration maintainer — confirm with the team |

> **Data Pipeline has no `.env`.** Its runtime credentials are Prefect Secret blocks fetched from the
> server at flow time, so its `env_status` in `.onboard-state.json` is the literal string `"n/a"` —
> and `"n/a"` **satisfies** the `env_files` gate. A strict `== "completed"` check would block
> `/workflow start` forever for anyone who selects it. Setup: onboard Steps 6b and 7.5.

### Collaboration configuration (web + api + hocuspocus)

Collaboration needs **all three** sides configured. Failure behavior differs: Studio/deck local
fallbacks can look editable without persistence, while other paths reject writes or become read-only.
Never treat a successful page render as evidence of sync or durable edits.

| Where | File | Key | Local value |
|---|---|---|---|
| Hocuspocus | `hocuspocus/.env` | `API_BASE_URL` | `http://localhost:9191/api` — **must include `/api`** |
| Hocuspocus | `hocuspocus/.env` | `DATABASE_URL` | the **API's** PostgreSQL DSN, not a separate database |
| Hocuspocus | `hocuspocus/.env` | `X_INTERNAL_TOKEN` | ≥ 20 characters, byte-identical to the API's `API_INTERNAL_TOKEN` |
| API | `api/.env` | `COLLAB_URL` | `http://127.0.0.1:1234` |
| API | `api/.env` | `API_INTERNAL_TOKEN` | the same secret as `X_INTERNAL_TOKEN` |
| Frontend | `web/.env.local` | `NEXT_PUBLIC_HOCUSPOCUS_URL` | `ws://localhost:1234` |

The effective `PORT` follows Node's native precedence: an exported ambient `PORT` overrides
`hocuspocus/.env`; otherwise the file/default applies. Use the same launch environment for checks.
A custom port also requires matching caller URLs and launch/health configuration; 1234 is only the
default. Do not reset a working custom port to match the example.

Rules for handling these values:

- **Never print, echo, or paste a real token** into chat, a report, a track file or a commit. Print
  only presence and length, e.g. `X_INTERNAL_TOKEN: set, 43 chars`.
- **The token is one value in two files.** Change both sides together or auth fails on one direction;
  never rotate or "fix" only one side, and never invent a shorter value — the floor is 20 chars.
- **Do not source a user's `.env` as shell code** (`source`, `set -a`, `eval`) to inspect it. Parse
  the keys you need, or let the service read the file.
- **`COLLAB_URL` is Hocuspocus's HTTP base reachable from the API**, not the API's own base URL.
  `127.0.0.1:1234` assumes local/co-located services; use the approved internal address otherwise.
  `NEXT_PUBLIC_*` is baked at build time — restart/rebuild the web app after changing it.
- Compare tokens with the runtimes' native parsers, not shell sourcing or hand-parsed lengths.
  Require byte equality and the minimum length; unverified configuration stays pending.
- **A missing `NEXT_PUBLIC_HOCUSPOCUS_URL` is a configuration gap, not an incident.** Studio and deck
  editing degrade to local-only state; page rendering still looks fine. Report it as configuration
  risk and point at the matrix above — do not "fix" application fallbacks, and do not describe it as
  a live outage.

### All Services

Use `./run-all.sh` from the workspace root to start all services concurrently.
Use `./run-all.sh --stop` to stop all running services.
Use `./run-all.sh --status` to check which services are running.

**Before starting services,** always check for port conflicts:
```bash
for port in 9191 3000 8000 9999 1234 8123 4200; do
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
