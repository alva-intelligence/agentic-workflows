## Service Registry

### Services

| Service | Directory | Repository | Stack | Default Branch | Port |
|---------|-----------|-----------|-------|---------------|------|
| API | `api/` | alva-intelligence/frnd-api-php | Laravel 13, PHP 8.5, PostgreSQL, Sanctum + JWT | `develop` | 9191 |
| Frontend | `web/` | alva-intelligence/frnd-web | Next.js 16, React 19, TypeScript, Tailwind CSS, Zustand, TanStack Query v5, Bun | `develop` | 3000 |
| AI Service | `ai-service/` | alva-intelligence/frnd-ai-services | FastAPI, Python, Agno, OpenAI/Anthropic/Google, pgvector, Redis | `development` | 8000 |
| Data Service | `data-service/` | alva-intelligence/frnd-clickhouse-api | FastAPI, Python, pandas, Sentry | `development` | 9999 |
| Orchestration | `orchestration/` | alva-intelligence/frnd-orchestration | Prefect 3, Python 3.12, ClickHouse, AWS S3, OpenAI | `staging` ¹ | — (no server) |

¹ Work branches from and PRs into `staging`. The repo's *default* branch is `main`, which is **production** — see below.

> ⚠️ **`orchestration/` breaks two assumptions the other four services share.** It is the
> **transformation layer** of a three-layer pipeline — Fivetran lands `raw_*_<brand>`, this repo
> writes `staging_<workspace>` and then `frnd_agg_marts.*`, and `data-service` serves the marts over
> HTTP. Nine platform families: facebook_pages, instagram_business, tiktok, youtube (organic);
> facebook_ads, tiktok_ads, google_ads (paid); gs_earned, gs_atl (Google Sheets).
>
> 1. **It claims no port and runs no long-running server.** Absent from `run-all.sh` by design.
>    Flows execute on the shared Prefect server; a local Prefect server on `:4200` is opt-in and
>    only needed for flow development.
> 2. **Its default branch is `main`, and `main` is what ships.** Every registered Prefect deployment
>    is registered **per environment** on one shared server (`prefect.frndos.com`).
>    Verified on the estate 2026-08-27: **production** deployments pull `main` (pool `local-pool`, queue `ads`); **staging** deployments pull `staging` (pool `staging-pool`, queue `ads-staging`, tag `branch:staging`), and both pools report `READY`, meaning a live worker is polling each. So a merge to `main` reaches **production**.
>
>    At flow *runtime* the environment is chosen separately, from the trigger's `callback_url`, and
>    **no `callback_url` means production** — so the branch axis and the runtime axis are independent
>    and both have to be right.
>
> **Feature work branches from `staging` and PRs into `staging`.** Reaching production is a **separate promotion PR, `staging` → `main`**, opened deliberately by a human — never as part of a feature. `main` is a strict ancestor of `staging` (43 behind, 0 ahead as of 2026-08-27), so the promotion is a clean merge. Open the PR and stop either way: never merge it yourself, never push to `staging` or `main`.
>
> Note `prefect.yaml` is **inert** — it carries `deployments: []`, so its `branch: main` pull step
> never executes. The real branch pin lives in `scripts/register_paid_deployments.py`, which takes a
> required `--env production|staging` and sets the branch, pool, queue and name suffix from it.
>
> Full rules: `orchestration/AGENTS.md` (18 hard rules) · plain-language tour:
> `orchestration/docs/START-HERE.md` · system map: `orchestration/docs/pipeline-map.md`.

### Service Owners & Contacts

| Service | Owner | Contact |
|---------|-------|---------|
| API | arhen | arhen |
| Frontend | fahrizky, daffa | fahrizky, daffa |
| AI Service | rifki | rifki |
| Data Service | kemal, iru | kemal, iru |
| Orchestration | fahmi (data engineer) + arhen (Fivetran/connectors) | fahmi, arhen |

> **Fivetran and connector changes are NOT part of a normal code change.** Enabling, pausing or
> re-scheduling a connector costs money on someone else's budget and belongs to arhen plus the data
> engineer. Raise it as its own request — never as a side effect of a metric change.

### Start Commands (EXACT — do NOT guess)

| Service | Command | Working Directory | Entry Point |
|---------|---------|-------------------|-------------|
| API | `php artisan optimize:clear && php artisan optimize && php artisan serve --port=9191` | `api/` | Laravel (artisan) |
| API Queue | `php artisan queue:work database --timeout=3000 --tries=5 --queue=high,low,default,subscriptions` | `api/` | Laravel queue worker |
| Frontend | `bun dev` | `web/` | Next.js dev server |
| AI Service | `source .venv/bin/activate && fastapi dev` | `ai-service/` | `main.py` via fastapi CLI |
| Data Service | `source .venv/bin/activate && uvicorn app.main:app --reload --port 9999` | `data-service/` | `app/main.py` (NOT `main:app`) |
| Orchestration | **none — there is nothing to start** | `orchestration/` | flows run on Prefect, not locally |
| Orchestration (tests) | `.venv/bin/pytest` | `orchestration/` | needs `requirements-dev.txt`; 1 known failure on both branches |
| Orchestration (local Prefect, opt-in) | `PREFECT_PROFILE=local .venv/bin/prefect server start` | `orchestration/` | binds `:4200`, flow dev only |

**IMPORTANT — orchestration:**
- **Do not add it to `run-all.sh`.** It has no long-running process. Its absence is a design
  decision, not an oversight.
- **Do not pass `-q` to pytest.** `pyproject.toml` already sets `addopts = "-q"`; passing it again
  makes it `-qq`, which suppresses the `N failed, N passed` summary line — so the run prints the
  failing test name and no counts, which reads far worse than it is.
- **No `PYTHONPATH=.` prefix is needed.** `pyproject.toml` sets `pythonpath = ["."]` and
  `testpaths = ["test"]`. Several docs inside that repo still tell you to prefix it — stale as of
  the commit that added the ini option, which is on `main`. Verified by collection, both
  `.venv/bin/pytest` and `python -m pytest`, with `PYTHONPATH` unset.
- **Never run `prefect profile use` or `prefect config set`** — they mutate `~/.prefect/profiles.toml`
  globally and silently retarget every later command, including the user's own terminal. Pin
  per-command instead: `PREFECT_PROFILE=frndos_prefect .venv/bin/prefect ...`. Both are denied in
  `.claude/settings.json`. The **one** exception is creating a missing `local` profile during
  onboarding Step 7.4.2, and even there the **user** runs it, not the agent.
- **Registering or re-registering deployments is operator-only.** `webhook-sync` and `webhook-delete`
  ids are frozen — data-service triggers them **by id**, and a new id silently breaks both
  environments (hard rule 13).

**IMPORTANT:** The Data Service entry point is `app.main:app` (module `app/main.py`), NOT `main:app`. The AI Service uses `fastapi dev` (which reads from the project config), NOT `uvicorn main:app`.

### Health Check Endpoints (EXACT — do NOT guess)

| Service | Check Command | Healthy If |
|---------|--------------|-----------|
| API | `curl -so /dev/null -w "%{http_code}" http://localhost:9191/api` | Any HTTP response = running |
| Frontend | `curl -sf http://localhost:3000` | 200 OK |
| AI Service | `curl -sf http://localhost:8000/health` | 200 OK |
| Data Service | `curl -so /dev/null -w "%{http_code}" http://localhost:9999/api/v1/health/` | 200 OR 401 (401 = running but auth-protected) |
| Orchestration | `cd orchestration && .venv/bin/pytest --collect-only -q` | exit 0 — **there is no endpoint to curl** |
| PostgreSQL | `pg_isready -h localhost -p 5432` | exit 0 |
| Redis | `redis-cli ping` | "PONG" |

**IMPORTANT:**
- The API health check is at `/api`. Any HTTP response = running.
- The Data Service health endpoint is auth-protected. A **401 response means the service IS running** — treat it as healthy.
- **Orchestration has no health endpoint and never will** — no server runs. Do not invent a URL for
  it and do not report it "down". **Collection** is the check, not a green suite: `main` carries one
  known failing test (`test_fb_pages_swap.py::test_substitution_order_when_reel_branch_real_with_inner_empty`).
  Measured on clean clones 2026-08-27: **`staging` 1 failed / 236 passed**, `main` 1 failed / 206
  passed — the same failure on 3.12 and 3.14 alike. Collection proves the venv, the deps and the
  import path; a failing assertion proves none of those.
- Do NOT guess health endpoints — use the URLs above.

### Environment Files

| Service | Env File | Contact for Credentials |
|---------|---------|----------------------|
| API | `api/.env` | arhen |
| Frontend | `web/.env.local` | fahrizky, daffa |
| AI Service | `ai-service/.env` | rifki |
| Data Service | `data-service/.env` | kemal, iru |
| Orchestration | **Prefect Secret blocks, not `.env`** | fahmi, arhen |

> Orchestration's runtime credentials — ClickHouse host/user/password, the data-service callback
> token, AWS keys — are Prefect Secret blocks fetched from the server at flow runtime, not
> environment variables (`orchestration/AGENTS.md` hard rule 10: never print or commit a block
> value). Committed template: `prefect_blocks.staging.example.yaml`. Real file:
> `prefect_blocks.staging.yaml`, gitignored. Setup: `scripts/setup_staging_blocks.py`, dry-run by
> default.
>
> ⚠️ That repo's `AGENTS.md` and `integrations/clickhouse.py` both name `prefect_blocks.example.yaml`
> and `scripts/setup_prefect_blocks.py`. **Neither has ever existed.** Use the `staging` names.

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

`orchestration/` claims no port, so it is absent from that loop on purpose. Two optional local
services do bind ports, and only when the developer opts into them: a local **Prefect** server on
`:4200` (onboard Step 7.5) and a local **ClickHouse** server on `:8123` HTTP + `:9000` native
(Step 7.4, shared with data-service). Add `4200 8123 9000` to the list above when either is in play.
