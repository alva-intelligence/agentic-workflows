# Local + staging pipeline end-to-end — intake brief, 2026-08-30

> ## ⚠️ Read this first — provenance and two falsified claims (added 2026-08-31)
>
> **This document was written on a different machine.** Its `file:line` citations were taken
> from working trees at `Work/frndos/<service>/`, a path that **does not exist** on this
> machine (`~/Work` is absent). This workspace is
> `~/Documents/Mijn Workbench/projects/frndos`. Everything below is preserved verbatim as the
> evidence record; the corrections are collected here rather than edited into the body, so the
> original claim and its refutation both stay readable.
>
> **§3 / onboarding Step 7.6 — FALSE on this machine.** The brief states the seeder probes
> `orchestration/scripts/seed_local_raw.py` and `scripts/local-seed-raw.py` and that *"Neither
> path exists anywhere in the workspace."* The first is indeed absent. **The second exists**:
>
> - `scripts/local-seed-raw.py` — 826 lines, executable, **tracked** at `0505be8`, mtime
>   2026-08-21 22:57. Declaration-driven from `orchestration/config_handover/*.yaml` — the exact
>   design §4.5 specifies. Localhost-guarded, `--list / --brand / --platforms / --posts / --drop`.
>   Covers **4 of 9** platforms: `ig`, `fb`, `tt`, `yt`. Organic only.
> - `scripts/local-run-pipeline.sh` — 86 lines. `PREFECT_PROFILE=local`, refuses to run unless the
>   `clickhouse-host` Secret block reads `localhost`, passes no `callback_url`.
>
> The work here is therefore **extend, not build**. Five platforms remain unseeded:
> `facebook_ads`, `tiktok_ads`, `google_ads`, `gs_earned`, `gs_atl`. §4.2's 67-table arithmetic
> and §4.5's generate-from-declarations rule are unaffected and still govern.
>
> **§4.5 reference DDL — off by one.** The brief says reference SQL is *"Present for 7 of 9"*.
> On this machine `data-service/database/reference/raw_sources/` holds six of the nine —
> `facebook_ads`, `facebook_pages`, `gs_atl`, `gs_earned`, `instagram_business`, `tiktok_ads` —
> plus `appsflyer`, which is not one of the nine platforms. Read it as **6 of 9**. The three
> needing capture are unchanged: `google_ads`, `tiktok`, `youtube` (D6).
>
> **Confirmed unchanged on this machine**, re-verified 2026-08-31: `.agentic-workflows/constants/`
> is absent and `demo-ulids.json` is duplicated at `api/` and `data-service/` (§4.3, FR-35's
> prerequisite still unmet); `run-all.sh` contains no Prefect or ClickHouse wiring (§4.6 item 1);
> `docker-compose.dev.yml` is absent entirely. Local runtime is **down** — nothing answers on
> `:4200` or `:8123`, though the `local` Prefect profile and `~/clickhouse-local/ch.sh` both exist.
>
> **Not re-verifiable this session:** the handoff §5 live-cluster findings. The `prefect-frnd` and
> `prefect-alva` MCP servers both fail `CONNECTION_CLOSED`, and `clickhouse-remote` is
> unauthenticated in a non-interactive session.



Scope: what it would take to run `raw → staging → mart` outside production. Covers the raw
seeder, the local runtime, per-environment cost control, the staging dummy brand, and run
visibility. Written as the intake for `/workflow start local-pipeline-e2e` and the four features
that follow it.

Method: local working trees at `Work/frndos/<service>/`, read directly. Every claim below
carries a `file:line` citation and was taken from code, not from documentation claims — where
a repo document and the code disagreed, the code was treated as authoritative and the
disagreement is recorded.

**This is not a PRD.** It is the evidence a PRD should be written from. Deliberately kept out
of `docs/prd/` so `frndos-prd` and `frndos-splitter` do not mistake it for one.

---

## 0. Provenance

| repo | branch | HEAD |
|---|---|---|
| orchestration | `staging` | `9ed71e5` 2026-08-27 |
| data-service | `development` | `346f0b9` 2026-08-27 |
| api | `develop` | `98c02701` 2026-08-27 |
| web | `develop` | `1e3a3f0ec` 2026-08-27 |
| `.agentic-workflows` | `feat/fahmi/orchestration-fifth-service` | v3.0.16 |

Two numbers below come from documents rather than from a checkout, and are marked where they
appear: the staging/production Prefect pool states (`orchestration/AGENTS.md`, measured
2026-08-27) and the six-staging-database table counts
(`docs/plans/2026-08-26-pipeline-contract.md` §5.3, measured 2026-08-27). Neither is
reproducible from inside a checkout.

---

## 1. Seven claims, checked

Four hold. Three are wrong in ways that change the plan.

| # | Claim | Verdict |
|---|---|---|
| 1 | Environment can be a property of the deployment (branch → pool → creds) | **already built** |
| 2 | Seeders only cover `frnd_agg_marts` | **mostly, but one raw seeder exists** |
| 3 | Staging Alembic was considered and declined | **the reverse is on record** |
| 4 | `staging_*` has no Alembic versioning | **confirmed** |
| 5 | Production-cost flows run unguarded below production | **confirmed, zero mitigation** |
| 6 | Local end-to-end is questionable | **worse — local cannot run at all** |
| 7 | Developers cannot see the pipeline progress | **the data is captured and discarded** |

### 1.1 Deployment-scoped environments already exist

`register_paid_deployments.py --env staging` pins branch `staging`, pool `staging-pool`, queue
`ads-staging`, and stamps `FRND_ENVIRONMENT=staging` via `job_variables`.
`integrations/clickhouse.py::_declared_environment()` reads it at runtime. data-service already
holds the staging deployment UUIDs.

- `orchestration/scripts/register_paid_deployments.py:152-184` — `ENV_POOL`, `ENV_BRANCH`, `ENV_SUFFIX`
- `orchestration/integrations/clickhouse.py:104-120` — `_declared_environment`, `_is_staging`
- `data-service/app/clients/prefect.py:56-66` — hardcoded staging UUIDs; production slots empty

Gaps: no `local` entry in the environment tables, and nothing cost-related keyed on the signal.
The registrar's `ENVIRONMENTS` tuple is `("production", "staging")` only.

### 1.2 A raw seeder exists, for one platform

`data-service/database/seeders/dummy_connector/000_seed_dummy_connector.py` (297 lines) stands
up `raw_fb_ads_<dummy>` with seven Fivetran-shaped tables plus `workspaces` / `brands` /
`connectors` / a SUCCESSFUL `connector_syncs`. Localhost-guarded, idempotent, `--drop`
supported. Its README states the intent directly: point the transform at it and it produces
`frnd_agg_marts.paid_ads_performance`.

Covers **1 of 9 platforms**. Reference DDL for 7 of 9 already exists at
`data-service/database/reference/raw_sources/*.reference.sql`. Do not rebuild — generalise.

### 1.3 Staging Alembic was decided *for*, not against

Ledger row `STAGING-VERSIONING`, 2026-08-27, rewrote `docs/plans/2026-08-26-pipeline-contract.md`
§5 specifically to overturn the earlier reconcile-only choice, quoting the requirement verbatim.
The stated reason for the rewrite: the earlier decision *"never asked the versioning question."*
Designed, not built.

### 1.4 `staging_*` carries no version record

Alembic covers `frnd_agg_marts` only — `m001`–`m020`, single head, applied inline at the top of
`platform_pipeline_flow` (`tasks/migrate_marts.py`). Measured 2026-08-27: six staging databases
carrying 21, 24, 29, 23, 24 and 24 tables, and zero versioning artefacts of any kind.

Two facts that block any claim about what is deployed:

- **Production `frnd_agg_marts` is unstamped.** A production sync reports `blocked_unstamped`
  and continues.
- **The claim that staging was stamped at `m020` was formally withdrawn as unverified**
  (`orchestration/AGENTS.md` §Migrations, guard 1).

### 1.5 No cost or feature flag exists anywhere

A grep of every `os.getenv` / `os.environ` across `flows/`, `tasks/` and `integrations/` returns
exactly five names: two RapidAPI host overrides, four RapidAPI path overrides,
`ENRICH_KOL_WORKERS`, `STAGING_DATE_CUTOFF`, and `FRND_ENVIRONMENT`. Sentiment, KOL enrichment
and S3 upload run unconditionally on every environment. Each is wrapped in `try/except`, which
makes them failure-tolerant, not optional.

The hooks that make this cheap already exist:

- `integrations/clickhouse.py:122-133` — `resolve_environment()` returns `local` / `staging` / `production`
- `flows/creative_assets/upload_flow.py:598-611` — the S3 key is **already** `{environment}/{platform}/{hash}`
- `integrations/openai_classifier.py:43` — `DEFAULT_MODEL = "gpt-5-mini"` is a bare module constant

### 1.6 Local cannot run the pipeline

`run-all.sh` starts four services (`:9191`, `:3000`, `:8000`, `:9999`).
`docker-compose.dev.yml` brings up Postgres, Redis, MailHog, ClickHouse. **No Prefect server, no
worker, no S3 substitute** in either.

On webhooks specifically: Fivetran webhooks are registered
`POST /v1/webhooks/group/<group_id>` (`data-service/app/clients/fivetran.py:132-166`) —
**group-scoped, not connector-scoped**. N developer tunnels against the shared group means every
developer receives every tenant's sync events. Two workable options remain: a developer brings
their own Fivetran destination group, or the `sync_end` body is replayed at `localhost:9999`.
`FIVETRAN_WEBHOOK_SKIP_SIGNATURE` exists for the second and is honoured only when
`APP_ENV=local` (`data-service/app/api/v1/webhook/fivetran/routes.py:104-115`).

### 1.7 Stage reports are written and never read

`platform_pipeline_flow` returns a per-stage dict — `migrate_marts`, `schema_check`,
`transform`, `creative_assets`, `enrich_*`, `marts`. The state hook POSTs it whole to
`/api/v1/webhook/prefect`, which writes it verbatim into
`frnd_os_master.prefect_event_log.payload_json`
(`data-service/app/api/v1/webhook/prefect/routes.py:149-168`).

**Nothing reads that table back.** No endpoint, no query, no UI — one smoke-test script and
nothing else. The tenant-facing chip in web is derived from ingestion status only and reads
"Connected" while a transform failed.

---

## 2. The estate, layer by environment

| Layer | Local | Staging | Production |
|---|---|---|---|
| **Raw** `raw_*_<brand>` | partial — 1 seeder, `facebook_ads` only | **none** — no connector, no seeded raw | live — Fivetran, 9 platforms |
| **Transform** Prefect | **none** — no server, worker, or `local` env | ready — 6 deployments, `staging-pool` / `ads-staging`, live worker ¹ | live — `local-pool` / `ads`, branch `main` |
| **Staging DB** `staging_<ws>` | unreachable — built by a flow that cannot run | exists, unversioned | exists, unversioned |
| **Marts** `frnd_agg_marts` | seeded — 30 SQL + demo + v2 generators | seeded — Alembic `m001`–`m020` | **unstamped** |
| **Cost surface** AI · RapidAPI · S3 | unguarded | unguarded — same model, key, bucket as prod | intended |
| **Run visibility** | none | write-only | write-only |

¹ Pool states from `orchestration/AGENTS.md`, measured on the estate 2026-08-27.

Read down the columns: production is the only complete environment. Read across the rows: every
gap sits at raw and staging, and none at the mart layer — the shape you get when the mart is the
only thing anyone ever seeded.

---

## 3. What `feat/fahmi/orchestration-fifth-service` already delivered

The branch this workspace runs (v3.0.16) added orchestration as service 5 and built more than
the service registration:

| Step | Content | State |
|---|---|---|
| 7.4 | Local ClickHouse — binary, server on `:8123`, `bootstrap/setup.sql`, the `frnd_meta.schema_migrations` tracker, all 93 migration files | built |
| 7.5 | Local Prefect — `local` profile, Secret blocks, `staging_date_cutoff` Variable, `local-pool`, deployment registration, worker, smoke test | built |
| **7.6** | **"Seed the local raw layer"** | **describes a script that does not exist** |

Step 7.6 probes `orchestration/scripts/seed_local_raw.py` and `scripts/local-seed-raw.py`, then
falls through to a literal `○ no local raw seeder found — ask fahmi`. Neither path exists
anywhere in the workspace. **This brief exists to close 7.6.**

`.onboard-state.json` on this workspace records `prefect_setup: completed` and
`ch_local: completed`. The seeder is the only missing piece locally.

### 3.1 Three things about 7.5 worth carrying forward

1. **Prefect is genuinely local.** Every command is prefixed `PREFECT_PROFILE=local`; the server
   is `127.0.0.1:4200`; `prefect profile use` and `prefect config set` are denied in
   `.claude/settings.json` so nothing can silently retarget the machine. No link to
   `prefect.frndos.com`.
2. **`local-pool` is a name collision, not a shared pool.** Production's pool carries the same
   name (`ENV_POOL["production"] = "local-pool"`). Different servers, no relationship.
3. **Two environment signals disagree on a local install.** 7.5.5 registers with
   `--env production`, which stamps `FRND_ENVIRONMENT=production`; 7.5.3 sets the `environment`
   Secret block to `local`. Harmless while `_declared_environment()` is only consulted to answer
   *"is this staging?"* — **decisive** once cost policy reads an environment. Settle which is
   authoritative before `env-cost-policy` starts.

### 3.2 The real production link is ClickHouse, not Prefect

Step 7.4.1 makes **Remote (a Cloud cluster) the default mode**. A local Prefect worker with
default blocks writes to staging or production ClickHouse. Local-server mode is opt-in and is
the only mode in which a raw seeder can run at all — the existing one refuses any host but
`localhost`. An offline chain requires local-server mode; it is not optional.

### 3.3 The registrar does not need a `local` environment

Earlier scoping assumed one was required. 7.5.5 registers locally with `--env production`,
producing the unsuffixed deployment names the local worker expects. That is simpler and already
works — **drop the `ENV_BRANCH` / `ENV_POOL` / `ENV_SUFFIX` addition from scope**, and resolve
§3.1 item 3 instead.

---

## 4. The seeder — specification

### 4.1 What is seeded, and what must never be

| Layer | Seed? | Reason |
|---|---|---|
| `raw_*_<brand>` | **yes** | Fivetran owns this in production. Nothing creates it locally. |
| `frnd_os_master` registry | **yes** | `workspaces` + `brands` + `connectors` + a SUCCESSFUL `connector_syncs`. Without these the trigger cannot resolve the tenant and the run dies before stage 1. |
| `frnd_os_master.connector_schemas` | **yes — `gs_earned` and `gs_atl` only** | Those two declare zero columns in their YAML (ALLOW_ALL by design) and read their column mapping from this table at runtime. |
| `staging_<workspace_id>` | **never** | A build product. `ensure_database` at `tasks/transform_helpers.py:553`; `CREATE TABLE IF NOT EXISTS` at `:317`, `:477`, `:843`. Pre-seeding manufactures exactly the drift the versioning work exists to eliminate. |
| `frnd_agg_marts` | **DDL only, no rows** | DDL already applied by onboarding Step 7.4.4 and by Alembic. Rows must arrive through the flow or the fixture proves nothing. |

### 4.2 Coverage — 67 raw tables across 9 platforms

| platform | alias | tables | `required=True` |
|---|---|---:|---:|
| instagram_business | `ig` | 6 | 2 |
| facebook_pages | `fb` | 10 | 2 |
| tiktok | `tt` | 7 | 2 |
| youtube | `yt` | 5 | 2 |
| facebook_ads | `fb_ads` | 14 | 5 |
| tiktok_ads | `tt_ads` | 10 | 5 |
| google_ads | `g_ads` | 12 | 5 |
| gs_earned | `gs_earned` | 1 | 1 |
| gs_atl | `gs_atl` | 2 | 1 |
| **total** | | **67** | **25** |

Source: `orchestration/domain/platforms.py::PLATFORM_RAW_TABLES`. `required=True` means the
preflight short-circuits the whole pipeline when the table is absent; the other 42 degrade
specific marts only.

### 4.3 Tenant shape — reuse the demo tenant

`data-service/database/seeders/frnd_agg_marts/demo/_constants.py::MART_DEFINITIONS` writes
**14 marts**, and **12 of them are exactly what the pipeline produces**:

| | marts |
|---|---|
| pipeline-produced (12) | `paid_ads_performance{,_age_gender,_region}`, `social_{channel,content}_performance`, `social_demographics_{age,city}`, `social_hashtag_tracker`, `social_sentiments`, `social_word_cloud`, `earned_content_data`, `atl_media_performance` |
| not pipeline-produced (2) | `campaign_performance`, `kpi_configs` — no loader exists in `tasks/load_marts.py` or `tasks/load_marts_paid.py` |

So: **keep 1 workspace + 3 brands and the same ULIDs**, seed raw for them, let the flow produce
the 12. The mart seeder shrinks to those 2, plus what was never mart-layer anyway —
`frnd_ai_database` narratives, `industry_benchmarks`, and the api Postgres side.

Identities (`demo-ulids.json`):

| | ULID |
|---|---|
| workspace `frndAgency` | `01ksrm715t7gkypw3vme4ex72q` |
| brand `frndbank` | `01ksrm715x6ptwyjjc9gtq9vys` |
| brand `frndskincare` | `01ksrm715zf0ejfeje5psv0kfz` |
| brand `frndairline` | `01KT20EM84NMY4H2F492PVF9VK` |

⚠️ **`demo-ulids.json` exists twice** — `api/demo-ulids.json` and
`data-service/demo-ulids.json`, byte-duplicated with no shared source. The PRD specified
`.agentic-workflows/constants/demo-ulids.json`; it was never created. The raw seeder is a third
consumer. Resolve in this feature or ship a third copy.

### 4.4 Sizing — cap the matrix, not the tables

The multiplier is **brand × platform**, not row count. 3 brands × 9 platforms = 27 raw
databases and 201 raw tables. A date-window cap does not touch that number.

Recommended: one brand carries all 9 platforms; the other two carry realistic subsets. The union
still covers all 9 platforms, all 4 dispatcher chains and all 12 marts, and what multi-brand
actually exercises — RLS isolation and cross-brand aggregation — needs two brands sharing *one*
platform, not three sharing all nine.

Row generation, per brand per platform:

| table class | rule |
|---|---|
| dimensions (`account_history`, `campaign_history`, `ad_history`, `profile`, `creative_history`) | fixed and small — ≤3 accounts, ≤5 campaigns, ≤10 ads. Everything else fans out from these. |
| facts (daily metrics) | `entities × days`, **days ≤ 30–60**. The only real multiplier. |
| comments (`post_comment_history`, `comment`) | hard cap ~200 per brand — this is the sentiment input and therefore the one table that costs money on the unstubbed path. |

**Dates must be generated relative to today, never absolute.** The existing fixture hardcodes
`START = date(2026, 1, 1)`. Two mechanisms punish that: the `staging_date_cutoff` Prefect
Variable (`2025-01-01` in production) drops older rows from staging *and* marts, and the web
app's default ranges are relative. A fixed-date fixture silently ages into an empty dashboard
that looks like a pipeline bug. A rolling 30–60 day window is the size cap and the freshness fix
in one knob.

### 4.5 Generate from declarations, never hand-write

Nine hand-written seeders would be a fourth copy of the schema, and would rot the first time
anyone adds a connector — silently, because a fixture missing a column produces an empty mart,
which looks like a pipeline bug. Read the three declarations that are already the source of
truth:

| input | supplies |
|---|---|
| `orchestration/domain/platforms.py` | which tables per platform, the `required` flag, raw DB naming (`PLATFORM_TO_RAW_ALIAS`) |
| `orchestration/config_handover/<platform>.yaml` | the Fivetran column allow-list — so a fixture cannot carry a column the transform ignores, or lack one it reads |
| `data-service/database/reference/raw_sources/*.reference.sql` | real column types. Present for 7 of 9; **`google_ads`, `tiktok`, `youtube` need capturing** |

Then "a new connector also needs a seeder" becomes a CI assertion rather than a habit: every
platform in `PLATFORM_RAW_TABLES` must resolve to a fixture, or the build fails.

### 4.6 The bootstrap procedure

`run-all.sh` starts long-running services; seeding and firing a pipeline is a one-time
bootstrap, the way `artisan migrate --seed` is not part of `artisan serve`. Three pieces:

1. **`run-all.sh` gains the Prefect server and worker as managed services.** They are currently
   two manual terminals (Step 7.5.2, 7.5.5), which is the main reason nobody keeps a local
   pipeline running.
2. **`bootstrap-pipeline.sh`** — idempotent and re-runnable: seed raw → seed registry → fire one
   run per brand × platform → poll to terminal → print mart row counts. This *is* Step 7.6.
3. **`run-all.sh` health check gains a mart-row probe.** Not an auto-run — a detection.
   Zero rows → print `○ marts are empty — run ./bootstrap-pipeline.sh`. That is how a developer
   is guaranteed to have run the flow before opening the web app, without hiding the pipeline
   behind a script nobody watches.

Fire the runs by **POSTing the Fivetran `sync_end` body at `localhost:9999`**, not by calling
`prefect deployment run` directly. It costs nothing extra and exercises the webhook signature
path, connector-name → tenant resolution, the Prefect trigger and the callback — four things
that break in production and that a direct deployment run skips entirely. Keep direct
`prefect deployment run` as the fallback for when data-service is not up.

---

## 5. Work order

Five waves, ordered by dependency. Wave 0 is independent.

| wave | slug | type | rationale |
|---|---|---|---|
| 0 | `pipeline-run-visibility` | feature · data-service | Stage reports already land in `prefect_event_log`; nothing reads them. It is the instrument the other four waves are debugged with. |
| 1 | ~~`local-pipeline-runtime`~~ | — | **Merged into `local-pipeline-e2e`** at intake 2026-08-30; not a separate feature. |
| 1 | `local-pipeline-e2e` | improvement · data-service + orchestration + api + workspace-root | §4, **merged with `local-pipeline-runtime` at intake 2026-08-30** and renamed. Closes onboarding Step 7.6. |
| 2 | `env-cost-policy` | feature · orchestration | Must land before Wave 3 or every staging run bills real vendors. |
| 3 | `staging-e2e-brand` | feature · orchestration + data-service | The dummy brand on staging. Also closes the four backfill deployments that reach production regardless of intent. |
| 4 | `staging-schema-versioning` | improvement · orchestration | **Owned by a separate session as of 2026-08-30 — do not start from this brief.** |
| 4 | `raw-schema-drift-detector` | feature · orchestration | Raw gets detection, not migrations — Fivetran owns that DDL. |

### 5.1 Wave 1 scope corrections against the artifact of 2026-08-30

- **Removed:** adding a `local` entry to the registrar's environment tables. See §3.3.
- **Added:** resolving the two conflicting environment signals. See §3.1 item 3.
- **Added:** retiring one of the two rival local ClickHouse servers. `docker-compose.dev.yml`
  runs one on `:8123`; `data-service/scripts/setup-local-demo.sh` downloads and starts a
  standalone binary on the same port. The compose file now mounts the
  `custom_settings_prefixes=SQL` config that originally justified the second one.

### 5.2 Known blockers carried in, not introduced here

- Production `frnd_agg_marts` is unstamped. Stamping it is an operator action, and it must
  stamp the **highest verified** revision established from `system.columns` — not `head`.
  Stamping head on a cluster missing `m018` marks it applied and the `clicks` column never
  appears.
- Three of six deployments — `staging-to-marts/backfill-social`,
  `staging-to-marts-paid/backfill-paid` and `testing-worker/smoke-testing` — never receive
  `callback_url` and therefore reach **production** regardless of intent
  (`orchestration/AGENTS.md` denylist row 16, verified against the flow signatures 2026-08-25).
  Only `webhook-sync`, `webhook-delete` and `backfill-ads` can be routed to staging.
  `FRND_ENVIRONMENT` already fixes this; it has never been promoted from an OR to the sole
  signal. Note `docs/plans/2026-08-24-per-env-deployments.md` says *four* — that count predates
  the signature check and is superseded by the denylist row.

---

## 6. Open decisions

Each is scoped under a stated recommendation so work is not blocked, but each changes the shape
of the result.

| # | Decision | Blocks | Recommendation |
|---|---|---|---|
| D1 | Which environment signal is authoritative — `FRND_ENVIRONMENT` or the `environment` block? | `env-cost-policy` | The `environment` block. `FRND_ENVIRONMENT` is `production` on a correct local install, so keying cost on it inverts the intent. |
| D2 | Local trigger — own Fivetran destination group, or replayed webhook body? | `local-pipeline-e2e` | Replayed body by default; own-group opt-in for whoever adds a genuinely new connector. Group-scoped webhooks make the shared-group version unworkable. |
| D3 | Brand × platform matrix — full 3 × 9, or one full brand plus two subsets? | `local-pipeline-e2e` | One full brand plus two subsets. §4.4. |
| D4 | Sentiment below production — cheaper model or deterministic stub? | `env-cost-policy` | Stub locally (a test can assert an outcome), cheap model on staging (the UI needs plausible distributions). |
| D5 | Where does the fixture generator live — orchestration or data-service? | `local-pipeline-e2e` | Open. Two of its three declaration inputs live in orchestration; the existing fixture and the registry writes live in data-service. |
| D6 | Which of `google_ads` / `tiktok` / `youtube` gets reference DDL captured first? | `local-pipeline-e2e` | Open. `test/fetch_google_ads_schema.py` already exists, making `google_ads` the cheapest. |

---

## 7. What this brief does not cover

- **`staging_*` schema versioning.** Decided 2026-08-27 (`STAGING-VERSIONING`), designed in
  `orchestration/docs/plans/2026-08-26-pipeline-contract.md` §5, and **owned by a separate
  session**. Recorded here only as §1.3 and §1.4 context.
- **`ORDER BY` changes on staging tables.** Deferred by decision — `ALTER … ADD COLUMN` cannot
  move a sort key, and one column already sits mid-key.
- **Promotion of orchestration `staging` → `main`.** A deliberate release decision, never part
  of a feature.
- **Any mutation on `prefect.frndos.com`.** Hard rule 8 — operator action, explicit confirmation.
