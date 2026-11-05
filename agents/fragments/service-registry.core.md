## Services (quick reference)

| Service | Dir | Port | Default Branch | Start |
|---------|-----|------|---------------|-------|
| API | `api/` | **9191** + pg `:5432` | `develop` | `php artisan serve --port=9191` |
| Frontend | `web/` | **3000** | `develop` | `bun dev` |
| AI Service | `ai-service/` | **8000** + pg `:5432`, redis `:6379` | `development` | `fastapi dev` |
| Data Service | `data-service/` | **9999** + ch `:8123`, prefect `:4200` | `development` | `uvicorn app.main:app --reload --port 9999` |
| Data Pipeline | `data-pipeline/` | prefect `:4200` + ch `:8123` | `development` | nothing in `run-all.sh`; both started by hand for flow work |
| Hocuspocus | `hocuspocus/` | **1234** + API pg `:5432` | `main` | `npm run dev` (Node ≥ 20.12; `npm ci` at setup) |
| Desktop | `desktop/` | — (native app) | `develop` | run from Xcode (SwiftUI, macOS 26+) |

> **Bold = the port the service itself serves on. Unbolded = a backing service it connects to.**
> Only the bold ones are `run-all.sh`'s to start, health-check or stop. Postgres `:5432`,
> Redis `:6379`, ClickHouse `:8123` and Prefect `:4200` are **shared infrastructure the developer
> runs**, so `run-all.sh` reports them and never kills them (`SHARED_PORTS` in the template).
> Data Pipeline is the row with no bold entry: it has no server of its own and is absent from
> `run-all.sh` by design — the two ports listed are what its flows talk to.

> ⚠️ **`data-pipeline/` is the transform layer.** Its branch model is the standard one, but two
> things differ from every other service. **(1) No port, no server:** it runs no long-lived process
> and is absent from `run-all.sh` by design, so there is nothing to start and nothing to
> health-check. **(2) No deploy step:** a Prefect worker polls each estate and clones the branch at
> run time, so a merge is live the moment it lands. It also has **no `.env`** — credentials are
> Prefect Secret blocks, so its `env_status` is `"n/a"`, which satisfies the onboarding gate. Full
> rules: `data-pipeline/AGENTS.md`.
>
> ⚠️ **`hocuspocus/` is the collaboration server (frnd-hocuspocus).** Four things differ:
> **(1) `main` is the base branch** — feature branches still required, PRs target `main`, and direct
> pushes to it are never allowed. **(2) No migrations or database of its own:** it stores Yjs updates
> in the API's already-migrated PostgreSQL (`DATABASE_URL`), and the API owns every schema change.
> **(3) Node ≥ 20.12** is a hard floor (`loadEnvFile` in `src/config.ts`); the onboarding Node 22 pin
> exceeds it, its own `engines` field only says 20. **(4) Health is `GET /health` on :1234**, and the
> `PORT`/timeout knobs stay configurable — never hardcode them into a service check.
>
> Persisted room types: bare deck ID, `kv_file:`, `doc:`, `studio:`. `proposal:`, `insight:` and
> `market:` are **presence-only** — losing them loses nothing, so never treat them as persistence.
> Without `NEXT_PUBLIC_HOCUSPOCUS_URL` (web) the Studio/deck editors fall back to local-only editing
> with no cross-client sync; that is a configuration gap to report, never proof collaboration works.
> No repo-local `AGENTS.md`/`CLAUDE.md` was present at the verified revision. Check again after
> cloning/updating and read any instructions that have since been added.
>
> **Optional services:** `data-pipeline/` (frnd-orchestration), `hocuspocus/` (frnd-hocuspocus) and
> `desktop/` (frnd-desktop) are deliberately optional — a developer may not have them cloned.
> `hocuspocus` is **included by default whenever Frontend is selected**, and skipped only on an
> explicit choice for unrelated work. Onboard one only when a task actually touches its domain (data
> flows / live editing and presence / native desktop app), and if a request arrives without the
> directory present, recommend onboarding it first instead of silently skipping. The Session Start
> Protocol carries this rule.

Full registry (owners, env files, exact start/health commands, port-conflict check): `skills/onboard/references/service-registry.md`.
