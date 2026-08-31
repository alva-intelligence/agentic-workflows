---
title: Local pipeline end-to-end
slug: local-pipeline-e2e
author: fahmi.zuhdi@alva.digital
created: 2026-08-31
status: draft
type: improvement
target_branch: improvement/fahmi/vc-local-pipeline-e2e
services: [workspace-root, data-service, orchestration, api]
supersedes: docs/briefs/2026-08-30-local-pipeline-e2e.md (evidence record, not spec); the 41-FR PRD written on another machine (unrecoverable — see DECISIONS-LEDGER W12)
---

# Local pipeline end-to-end

## Overview

Run `raw -> staging -> mart` on a developer's own machine, end to end, without Fivetran,
without the shared Prefect server on `prefect.frndos.com`, and without touching ClickHouse
Cloud. This is what onboarding Step 7.6 ("Seed the local raw layer") calls for and does not
currently provide, so a local ClickHouse holds placeholder raw tables, every transform reads
nothing, and every metric downstream renders as an em dash that looks like a pipeline bug but
is an absent source.

The feature merges two originally-separate concerns — the declaration-driven raw-fixture
generator, and the local runtime that executes it — because neither ships value on its own. It
is scoped as an **extension**, not a build: `scripts/local-seed-raw.py:1-826` and
`scripts/local-run-pipeline.sh:1-86` already implement the design the audit brief §4.5
specifies, for four of the nine platforms and via an in-process trigger. Five platforms
(`facebook_ads`, `tiktok_ads`, `google_ads`, `gs_earned`, `gs_atl`) and one fourth brand
(`yourfragrance`) still need seeding, one hardcoded start-date needs to become a rolling
window, one S3 upload step needs a local skip guard, and the bootstrap order needs to be
documented. The old 41-FR PRD written on another machine is unrecoverable (see
`docs/DECISIONS-LEDGER.md` row `W12`); the 17 decisions behind it survive and are re-derived
here against what is actually built on this machine.

Services in scope: **workspace-root, data-service, orchestration, api.** Web is out of scope —
it consumes the marts this feature produces but requires no change.

### Existing System Reconciliation

Verified against this workspace 2026-08-31. Where a claim is carried on the handoff's
authority alone because the live cluster could not be reached this session (`prefect-frnd` and
`prefect-alva` MCP servers both `CONNECTION_CLOSED`, `clickhouse-remote` unauthenticated in a
non-interactive session), the requirement below says so.

- **The seeder script already exists.** `scripts/local-seed-raw.py` is 826 lines, tracked at
  `0505be8` since 2026-08-21, executable, and declaration-driven from
  `orchestration/config_handover/*.yaml` — the exact shape §4.5 of the brief mandates. It
  covers `ig` (instagram_business), `fb` (facebook_pages), `tt` (tiktok), `yt` (youtube). Its
  author excluded paid and Google-Sheet shapes as *"very different shapes"* at `:51-53`.
- **The runner script already exists.** `scripts/local-run-pipeline.sh` is 86 lines, sets
  `PREFECT_PROFILE=local` at `:34`, refuses to run unless the `clickhouse-host` Secret block
  reads `localhost`/`127.0.0.1` at `:41-47`, and invokes `platform_pipeline_flow` **in
  process** via a Python one-liner at `:53-56` — no Prefect API trigger, no callback JWT
  wiring.
- **Reference DDL is 6 of 9**, not 7 as the brief §4.5 claims. Present at
  `data-service/database/reference/raw_sources/`: `facebook_ads`, `facebook_pages`, `gs_atl`,
  `gs_earned`, `instagram_business`, `tiktok_ads`, plus `appsflyer` which is not one of the
  nine platforms. **To capture:** `google_ads`, `tiktok`, `youtube`.
- **The 9-platform / 67-table matrix is correct.** `orchestration/domain/platforms.py:39-49`
  declares `PLATFORM_TO_RAW_ALIAS` (9 aliases: `tt`, `tt_ads`, `yt`, `fb`, `fb_ads`, `g_ads`,
  `ig`, `gs_earned`, `gs_atl`); `orchestration/domain/platforms.py:258+`
  `PLATFORM_RAW_TABLES` totals 67 rows. All nine YAML declarations are present under
  `orchestration/config_handover/` — the missing five have their declaration inputs ready.
- **`demo-ulids.json` is not byte-duplicated any more.** `api/demo-ulids.json` has 7 keys
  including `yourfragrance_brand_ulid` (matching `DemoUlids::yourFragranceBrandUlid()` and
  `api/database/seeders/DemoWorkspaceSeeder.php:438-668`); `data-service/demo-ulids.json` has
  6 keys and omits it. The drift is **intentional**, per
  `data-service/database/seeders/frnd_agg_marts/demo/_constants.py:1-19` (*"Checking the file
  into the repo root … keeps the seeder runnable from a standalone
  `frnd-clickhouse-api` checkout"*). The brief §4.3's "byte-duplicated with no shared source"
  is stale.
- **`.agentic-workflows/constants/` does not exist**, and neither consumer would find a file
  there. The old FR-35 (create `constants/demo-ulids.json` and land the upstream
  agentic-workflows PR) is **retired** by the resolution below, so that PR is no longer a
  blocker for this feature.
- **`docker-compose.dev.yml` and `bootstrap-pipeline.sh` are both absent.**
- **`run-all.sh` contains no Prefect or ClickHouse wiring** — a grep for
  `prefect|clickhouse|:4200|:8123|mart` returns nothing.
- **`.onboard-state.json` on this workspace has no `prefect_setup` or `ch_local` keys.**
  The local ClickHouse binary is present at `~/clickhouse-local/ch.sh` (arrived 2026-08-10,
  not via onboarding Step 7.4). The `local` Prefect profile exists in `~/.prefect/profiles.toml`.
  Both services are **down** this session (`:4200` and `:8123` both closed); Fahmi deselected
  starting them. Nothing in this PRD is verified against a live local stack.
- **`data-service/scripts/setup-local-demo.sh:44-59`** already downloads the standalone
  ClickHouse binary into `$CH_LOCAL_DIR` (default `~/clickhouse-local`), creates the
  `frndos_data_service` / `demo_local_pw` user (`:66-70`), and calls
  `data-service/database/seeders/frnd_agg_marts/demo/seed_demo.py`, which writes the
  `frnd_os_master` registry rows for the three demo brands. The `apply_dir()` word-splitting
  fix for paths containing a space (`:85`, the `while IFS= read -r -d ''` form) is already
  present in the merged branch this workspace runs.
- **Base-branch drift.** All four service repos sit on the merged
  `feature/fahmi/vc-insights-missing-metrics`, 0 ahead of origin. Behind counts:
  `data-service` 17, `orchestration` 4, `api` 560, `web` 422. The splitter is responsible for
  branching from each service's canonical base; this PRD does not create branches or commit
  service code.
- **Live-cluster claims (handoff §5) not re-verifiable this session** and carried on the
  handoff's authority alone: STAGING serviceId `594e5d1d-753c-400d-ab94-e9a8bf193b07`,
  PRODUCTION serviceId `64cc32f0-3a02-49f1-a88d-8967cf6e9677`, `e8448wgdki` ("ALVA
  Intelligence") stopped; staging raw coverage 7/9 (missing `tt` organic and `g_ads`),
  production 9/9; production raw DB names embed real client brand ULIDs; multi-connector
  naming `raw_<alias>_<n>_<brand>` (e.g. `raw_g_ads_2_*`, `raw_tt_5_*`) live in production;
  two benign registry-vs-live diffs (`google_ads` lacks `custom_report_lead` by design per
  OUT-027, `tiktok` carries an extra `creative_assets` that is transformer-owned per
  `orchestration/flows/creative_assets/ddl.py:12` and correctly absent from
  `PLATFORM_RAW_TABLES`).

### Assumptions and Clarifications

The six brainstorming disturbances were resolved this session (Fahmi took every
recommendation) and the eleven carried decisions were re-verified. The six PRD-review open
questions were then finalised — four matching the recommended defaults, two overriding
them:
`q-onboarding-state-scope` = `close_in_setup_local_demo` (rewrote FR-27, added NFR-11), and
`q-dummy-connector-deprecation-scope` = `deprecate_banner` (added FR-29). Nothing below is a
fresh guess; each has a settled answer, and each requirement that rests on one is annotated
in prose so a reader can trace it back to the resolution rather than reusing the retired
FR-35 number. Every open question is listed as answered in the Open Questions section, kept
for the record; nothing there is blocking.

- **Seeder home** = extend `scripts/local-seed-raw.py` in place. Deprecation of
  `data-service/database/seeders/dummy_connector/000_seed_dummy_connector.py` is a **follow-up
  feature**, not part of this one, so no requirement here retires it.
- **ClickHouse runtime** = standalone binary only. Windows developers use WSL or the native
  binary. `docker-compose.dev.yml` is dropped from scope entirely; brief §5.1's
  two-servers-on-`:8123` rivalry is settled by the drop.
- **S3 / `creative_assets`** = a guard at the top of
  `orchestration/flows/creative_assets/upload_flow.py` returns `{status: 'skipped_local'}` by
  default when environment is `local`. Opt-in needs only real `aws-*` Secret blocks, because
  the env-scoped S3 key at `orchestration/flows/creative_assets/upload_flow.py:598-611` already
  emits the `{environment}/...` prefix once `resolve_environment()` returns `'local'`. MinIO
  is dropped from scope; `orchestration/integrations/aws.py` is not touched.
- **Paid / Google-Sheet shapes** = added in place to the existing `Seeder` class in
  `scripts/local-seed-raw.py`, mirroring `rows_ig`/`rows_fb`/`rows_tt`/`rows_yt` at
  `:321-741`. No sibling scripts, no class hierarchy; `insert()` at `:286` and `_ch_type()` at
  `:106` stay unchanged.
- **Trigger path** = keep the in-process call at `scripts/local-run-pipeline.sh:53-56` as the
  default. **Stated cost, accepted:** the local loop never exercises the
  trigger → worker → state-hook path production runs through, and runs are invisible to the
  Prefect UI. The Prefect-API-poll and Fivetran-webhook body paths stay reachable as later
  add-ons under the separate `pipeline-run-visibility` feature (brief §5 Wave 0). This is
  captured as NFR-2 rather than as a future FR.
- **`demo-ulids.json`** = per-service files stay. The old `.agentic-workflows/constants/`
  consolidation is retired in all three of its forms; the upstream agentic-workflows PR that
  gated it is no longer a blocker. Deliverable: a CI probe or docstring that records the
  intentional 3-brand vs 4-brand asymmetry (FR-15).
- **Environment-signal authority.** The carried decision `q-env-signal-authority` = *the
  `environment` Secret block is authoritative* describes a **future direction, not current
  code**. Today `orchestration/integrations/clickhouse.py:114-120` is an OR
  (`_declared_environment() == "staging" or _is_staging_callback()`), with the Secret block a
  fallback only. This feature does **not** change that; a change would ripple into
  `env-cost-policy` (brief §5 Wave 2). Any requirement that appears to demand the change
  requires an explicit ledger row and is out of scope here.
- **Reference-DDL capture is precondition-gated.** The handoff's staging/production service
  ids, raw-coverage split and multi-connector naming could not be re-verified this session.
  The capture requirement (FR-16) is written with an explicit precondition that these
  findings be re-verified before any script targets a cluster, and mandates that the capture
  genericise real brand ULIDs and never commit one.
- **Staging reference brand.** `q-staging-reference-brand-proposal` = *defer to the PM /
  tech-lead discussion*. No requirement here assumes an answer.

## Brainstorming Outcome

_Pulled verbatim from `features["local-pipeline-e2e"].brainstorming.summary`._

Re-brainstormed against this machine's actual state 2026-08-31. The feature's real shape is
EXTEND a working generator from 4 platforms to 9 — not build one — because
scripts/local-seed-raw.py (826 lines, tracked 0505be8) already implements the
declaration-driven design brief §4.5 specifies for organic ig/fb/tt/yt, and
scripts/local-run-pipeline.sh already invokes platform_pipeline_flow in-process against a
localhost-guarded Prefect+ClickHouse. Missing platforms: facebook_ads, tiktok_ads, google_ads,
gs_earned, gs_atl; all five have their config_handover/*.yaml declarations in orchestration/,
so the extension has its declaration inputs ready. Six of nine reference DDLs are already at
data-service/database/reference/raw_sources/ (google_ads, tiktok, youtube still to capture —
dependent on cluster access that this session cannot verify). Six of the seventeen carried
decisions are DISTURBED by code and must be re-asked before the PRD can be re-derived:
q-generator-home (three candidate homes now live, not two), q-clickhouse-runtime
(docker-compose.dev.yml absent, blessed Windows path missing), q-s3-substitute (MinIO not
integrated anywhere, aws.py has no endpoint_url plumbing, real-S3-with-`local/`-prefix
already works), q-bootstrap-polling (current invocation is in-process direct, neither
poll-API nor callback-JWT), q-demo-ulids-consolidation (the code comment at data-service
demo/_constants.py:1-19 explicitly rejects the `.agentic-workflows/constants/` consolidation
path for standalone-checkout portability, and api/data-service copies have already drifted
intentionally over yourfragrance), and q-paid-gs-shape-extension (new — how the excluded
shapes fit an organic-only script). The remaining eleven carried decisions verify: work type
/ branch / scope, q-reference-ddl (capture the three), q-brand-platform-matrix,
q-env-signal-authority (a future direction, not current code), q-yourfragrance-4th-brand
(already materialised in api's DemoWorkspaceSeeder), q-api-integration-rows,
q-one-full-brand-choice=frndbank, q-staging-reference-brand-proposal=defer,
q-shared-platform-set (api's tuples are in api/database/seeders/DemoWorkspaceSeeder.php),
q-clickhouse-credentials-choice (setup-local-demo.sh already uses
frndos_data_service/demo_local_pw), q-fixture-implementation-language (already Python). The
workspace-root seeder does NOT write frnd_os_master registry rows — it only reads
account_ownership; the registry rows must be seeded by data-service/scripts/setup-local-demo.sh
(which runs seed_demo.py) BEFORE the raw seeder runs, so bootstrap documentation must call out
the order. Handoff §5 live-cluster findings could not be re-verified this session (prefect-frnd
/ prefect-alva CONNECTION_CLOSED, clickhouse-remote unauthenticated); do not run
reference-DDL capture against a cluster until re-verified. Base branch drift status: api HEAD
0 ahead of origin/develop 560 behind; web 0/422; data-service 0/17; orchestration 0/4. All
four services sit on the merged feature/fahmi/vc-insights-missing-metrics — new branches from
base are still pending (see handoff §4).

RESOLVED 2026-08-31 — all six disturbances answered by Fahmi, every one taking the
recommendation:
(1) q-generator-home-revisit = extend_workspace_root_in_place — scripts/local-seed-raw.py
stays the canonical seeder and grows the 5 platforms; data-service/database/seeders/dummy_connector/
is deprecated in a follow-up, not in this feature. The carried "generalise dummy_connector/"
answer is retired. (2) q-clickhouse-runtime-revisit = standalone_binary_only — the binary
that data-service/scripts/setup-local-demo.sh:44-59 downloads into $CH_LOCAL_DIR is the
single path; Windows goes via WSL or the native binary; docker-compose.dev.yml is dropped
from scope entirely, which also settles brief §5.1's two-servers-on-:8123 rivalry.
(3) q-s3-substitute-revisit = skip_locally_default_real_s3_opt_in — a guard at the top of
upload_flow.py returns {status:'skipped_local'} by default; opting in needs only real aws-*
Secret blocks, because the env-scoped S3 key at upload_flow.py:598-611 already emits the
local/ prefix once resolve_environment() returns 'local'. MinIO is dropped;
orchestration/integrations/aws.py is not touched. (4) q-paid-gs-shape-extension =
in_place_per_platform_builders — rows_fb_ads / rows_tt_ads / rows_g_ads / rows_gs_earned /
rows_gs_atl join the existing Seeder class mirroring rows_ig/rows_fb/rows_tt/rows_yt at
:322-741, with PLATFORMS (:55) and REQUIRED_COLUMNS (:136) extended and per-platform
TYPE_OVERRIDES added; insert() and _ch_type() stay unchanged. No sibling scripts, no class
hierarchy. (5) q-pipeline-invocation-revisit = keep_in_process_direct — the in-process call
at scripts/local-run-pipeline.sh:53-56 remains the default. STATED COST, accepted: the local
loop never exercises the trigger → worker → state-hook path production runs through, and
runs are invisible to the Prefect UI. The Prefect-API-poll and Fivetran-webhook paths stay
available as later add-ons for pipeline-run-visibility (brief §5 Wave 0). The carried
q-bootstrap-polling answer is retired. (6) q-demo-ulids-consolidation-revisit =
keep_per_service_files_drop_consolidation — consolidation leaves scope in all three of its
forms. VERIFIED independently 2026-08-31: the two files differ by md5 (api 7 keys including
yourfragrance_brand_ulid, data-service 6 without), so the brief §4.3 description
"byte-duplicated with no shared source" is STALE and the drift is intentional per
data-service/database/seeders/frnd_agg_marts/demo/_constants.py:1-19. The old FR-35 and its
upstream agentic-workflows PR prerequisite are retired with it — that PR is no longer a
blocker for this feature.

Net effect on the carried set: 6 of 17 decisions retired or rewritten, 11 verified and
standing. Three of the six resolutions REMOVE scope (MinIO, docker-compose.dev.yml, the
constants/ consolidation and its upstream PR); one ADDS a stated cost that must appear in the
PRD's non-functional section (no production-path fidelity in the local trigger).

### Decisions

Every question with a final answer. Six were re-asked this session because code had disturbed
the earlier answer; eleven were carried through unchanged. Answers marked *(disturbance
resolution)* replace an earlier carried answer.

- **q-generator-home-revisit — Which existing seeder becomes the canonical home for the
  5-platform extension?** → `extend_workspace_root_in_place`. Extend
  `scripts/local-seed-raw.py` in place. *(disturbance resolution — replaces "data-service,
  generalise `dummy_connector/`")*
- **q-clickhouse-runtime-revisit — How is local ClickHouse provisioned across OSes?** →
  `standalone_binary_only`. Windows via WSL or native binary; `docker-compose.dev.yml`
  dropped. *(disturbance resolution — replaces "keep both, platform-conditional")*
- **q-s3-substitute-revisit — How does the local runtime handle the `creative_assets` S3
  upload step?** → `skip_locally_default_real_s3_opt_in`. Guard at top of `upload_flow.py`;
  real AWS via existing `aws-*` Secret blocks. *(disturbance resolution — replaces "MinIO as
  default local driver")*
- **q-paid-gs-shape-extension — How should the 5 missing platforms be added?** →
  `in_place_per_platform_builders`. Mirror the existing `rows_ig/rows_fb/rows_tt/rows_yt`
  builders; extend `PLATFORMS` and `REQUIRED_COLUMNS`; add per-platform `TYPE_OVERRIDES`;
  leave `insert()` and `_ch_type()` unchanged.
- **q-pipeline-invocation-revisit — How does `local-run-pipeline.sh` trigger the flow?** →
  `keep_in_process_direct`. In-process call at `:53-56` remains the default. *(disturbance
  resolution — replaces "poll the Prefect API directly")*
- **q-demo-ulids-consolidation-revisit — Does `demo-ulids.json` get consolidated?** →
  `keep_per_service_files_drop_consolidation`. `.agentic-workflows/constants/` consolidation
  retired; intentional 3-brand vs 4-brand asymmetry documented. *(disturbance resolution —
  replaces "consolidate now to `.agentic-workflows/constants/demo-ulids.json`")*
- **Work type / branch / scope** (intake) → `improvement`; branch
  `improvement/fahmi/vc-local-pipeline-e2e` (splitter derives from `type`); scope = fixtures
  **+ full local runtime**, merged.
- **q-reference-ddl — Which of `google_ads` / `tiktok` / `youtube` gets reference DDL captured
  first?** → **all three**. Precondition-gated (see FR-16); no capture without re-verifying
  the handoff §5 findings.
- **q-brand-platform-matrix — Full 3×9 or one-full-brand plus subsets?** → **one full brand
  plus subsets.**
- **q-env-signal-authority — Which environment signal is authoritative?** → **the
  `environment` Secret block** — *future direction, not current code.* This PRD does not
  change `orchestration/integrations/clickhouse.py:114-120`; that change is owned by
  `env-cost-policy` (brief §5 Wave 2).
- **q-yourfragrance-4th-brand — Add as 4th brand with subset?** → **yes**. Already
  materialised in `api/database/seeders/DemoWorkspaceSeeder.php:438-668`.
- **q-api-integration-rows — Which brands get api integration rows?** → **full brand only**
  (`frndbank`).
- **q-one-full-brand-choice — Which is the full brand?** → **`frndbank`.**
- **q-staging-reference-brand-proposal** → **defer** to PM / tech-lead discussion; no
  requirement here assumes an outcome.
- **q-shared-platform-set — Which platforms per brand?** → **matched to api's tuples** in
  `api/database/seeders/DemoWorkspaceSeeder.php`.
- **q-clickhouse-credentials-choice** → `frndos_data_service` / `demo_local_pw` — already
  what `data-service/scripts/setup-local-demo.sh:66-70` creates.
- **q-fixture-implementation-language** → **Python** — already the case; no change.

## User Stories

- **US-1 — Onboarding a new engineer.** As a new engineer running `data-service/scripts/setup-local-demo.sh`
  followed by `scripts/local-seed-raw.py` and `scripts/local-run-pipeline.sh`, I can bring up
  a local ClickHouse populated across the four demo brands with all nine platforms exercised
  on `frndbank`, run the transform+mart pipeline end to end without touching Cloud, and see
  non-em-dash rows in `frnd_agg_marts.social_content_performance FINAL` — so I can develop
  against the pipeline the way it actually behaves.
- **US-2 — Reproducing a mart regression locally.** As a maintainer chasing an em-dash bug
  reported on production, I can seed the exact platform+brand combination locally, re-run the
  pipeline in seconds, and inspect the transform output on a fixture whose date window is
  fresh enough that `staging_date_cutoff` doesn't drop it — so I catch the regression in the
  transform rather than in production monitoring.
- **US-3 — Working on the fifth (fourth demo) brand.** As an engineer wiring api-only
  features against `yourfragrance`, I have a raw layer and marts that match the 5-platform
  subset `DemoWorkspaceSeeder` registers, so my api tests don't half-run against a brand that
  has no upstream data.
- **US-4 — Adding a new connector without silently breaking the fixture.** As an engineer
  adding a tenth platform to `orchestration/domain/platforms.py::PLATFORM_TO_RAW_ALIAS`, I
  get a CI failure that names my platform, rather than a mart that silently returns zero
  rows because `scripts/local-seed-raw.py::PLATFORMS` never learned about it.
- **US-5 — Running the local pipeline without leaking to production.** As any developer, I
  can trust that `scripts/local-run-pipeline.sh` cannot reach `prefect.frndos.com` or the
  Cloud ClickHouse services even if my Secret blocks are misconfigured — the localhost guard
  refuses to run, and the S3 upload step returns `{status: 'skipped_local'}` unless I have
  explicitly configured real `aws-*` Secret blocks.

## Requirements

Requirements are numbered from FR-1. The old 41-FR numbering (from the PRD written on another
machine and lost) is not preserved. Where a carried decision referenced an old number — most
notably FR-35, the `.agentic-workflows/constants/demo-ulids.json` consolidation — the answer
is described in prose and the requirement is either recast (FR-15) or retired (the
consolidation itself).

Every FR carries `file:line` evidence. Claims that rest on the handoff's authority alone —
because `prefect-frnd`, `prefect-alva` and `clickhouse-remote` MCPs are unavailable this
session — are labelled *(handoff-authority, re-verify before acting)* inline. Content is
ranked by consequence; a minor point lands last rather than being dropped.

### Functional Requirements

**Seeder extension — `scripts/local-seed-raw.py`**

- **FR-1: Extend `PLATFORMS` from 4 to 9 entries.** Add `fb_ads` →
  `("facebook_ads", "facebook_ads.yaml")`, `tt_ads` →
  `("tiktok_ads", "tiktok_ads.yaml")`, `g_ads` → `("google_ads", "google_ads.yaml")`,
  `gs_earned` → `("gs_earned", "gs_earned.yaml")`, `gs_atl` → `("gs_atl", "gs_atl.yaml")`, to
  the `PLATFORMS` mapping at `scripts/local-seed-raw.py:55-60`. The five YAMLs are already
  present at `orchestration/config_handover/{facebook_ads,tiktok_ads,google_ads,gs_earned,gs_atl}.yaml`
  and are the declaration input `load_contract()` at `:169-189` reads. The comment at
  `:53-54` that says the script is organic-only must be removed or rewritten.

- **FR-2: Add per-platform row builders for the five new platforms.** New methods
  `rows_fb_ads`, `rows_tt_ads`, `rows_g_ads`, `rows_gs_earned`, `rows_gs_atl` on the
  `Seeder` class, each following the shape of the existing `rows_ig` / `rows_fb` / `rows_tt`
  / `rows_yt` at `scripts/local-seed-raw.py:321-741`: return a `{table: [row dicts]}` mapping
  covering every table that appears in the YAML contract; set only the columns that carry
  meaning (foreign keys, dates, metrics under test) and rely on `insert()` at `:286-312` to
  fill contract columns the builder omits. `insert()` and `_ch_type()` MUST NOT be modified.
  `Seeder.seed_platform(alias, drop)` at `:743-772` already dispatches via
  `getattr(self, f"rows_{alias}")`, so no dispatch change is needed.

- **FR-3: Add per-platform `TYPE_OVERRIDES` for columns the name-based `_ch_type()` guess
  gets wrong or where the value carries meaning.** Extend the module-level `TYPE_OVERRIDES`
  dict at `scripts/local-seed-raw.py:77-91`. At minimum: campaign spend / ad spend as
  `Nullable(Float64)`, `gs_earned` and `gs_atl` date columns (which arrive as ISO strings on
  the Google-Sheet source), and any action-type EAV columns the paid transformers argMax off.
  Every override MUST be accompanied by a one-line comment explaining the wrong guess and the
  correct type, mirroring the format at `:78-91`.

- **FR-4: Add `REQUIRED_COLUMNS` entries for allow-list ↔ transform drift on the five new
  platforms.** Extend the `REQUIRED_COLUMNS` dict at `scripts/local-seed-raw.py:136-166`
  with any column the platform's transformer reads that the YAML does not enable. Regenerate
  by grepping `flows/<platform>/transform_flow.py` for `argMax\(\s*[a-z_0-9]+` per the
  existing comment at `:134-135`, then diffing against the columns
  `load_contract()` returns. Missing this step will surface as `NO_SUCH_COLUMN_IN_TABLE` at
  transform time, not at seed time.

- **FR-5: Extend the `--platforms` CLI flag default to include all nine aliases.** The
  default at `scripts/local-seed-raw.py:778` is `"ig,fb,tt,yt"`; must become
  `"ig,fb,tt,yt,fb_ads,tt_ads,g_ads,gs_earned,gs_atl"`. The argument-validation loop at
  `:815-818` already refuses unknown aliases against `PLATFORMS`, so extending `PLATFORMS`
  (FR-1) also extends validation; no code there changes.

- **FR-6: Replace the hardcoded absolute date base with a rolling window relative to today.**
  `Seeder.__init__` at `scripts/local-seed-raw.py:215` currently sets
  `self.base = datetime(2026, 8, 1, 9, 0, 0)`. It MUST become a rolling window ending at
  today (`datetime.utcnow()` or `datetime.now(timezone.utc)`, so the fixture never straddles
  a timezone boundary that could push a row past `staging_date_cutoff` mid-day) with a
  configurable window size in days, defaulting to `30`. Two failure modes this closes: the
  `staging_date_cutoff` Prefect Variable (`2025-01-01` in production) drops staging and mart
  rows older than the cutoff, and web's default ranges are relative — a fixed-date fixture
  silently ages into an empty dashboard that reads as a pipeline bug.

- **FR-7: Add a `--days` CLI flag (default `30`, capped at `60`) that drives the rolling
  window.** The cap keeps fixture size predictable and matches brief §4.4's guidance that
  `entities × days` is the only real fact-table multiplier. Documented in `--help` so a
  developer investigating volume knows the knob exists.

**Bootstrap ordering — workspace-root**

- **FR-8: Document the mandatory run order in `scripts/local-seed-raw.py` module docstring
  and in `scripts/local-run-pipeline.sh` header comment.** The order is:
  `data-service/scripts/setup-local-demo.sh` (which downloads the ClickHouse binary at
  `:44-59` and runs `data-service/database/seeders/frnd_agg_marts/demo/seed_demo.py`,
  populating `frnd_os_master.workspaces` / `brands` / `connectors` for the three demo brands)
  → `scripts/local-seed-raw.py` (per brand, per platform) → `scripts/local-run-pipeline.sh`.
  `scripts/local-seed-raw.py:238` only **reads** `frnd_os_master.account_ownership` via
  `Seeder.registered_account()` at `:227-243`; it does NOT write registry rows (contrast
  `data-service/database/seeders/dummy_connector/000_seed_dummy_connector.py:228-243`, which
  writes `workspaces`/`brands`/`connectors`/`connector_syncs` and is the older, single-platform
  fixture the resolution has retained but not deprecated in this feature). Running
  `local-seed-raw.py` first will silently produce fixtures whose transforms lose the
  `account_name` LEFT JOIN — the exact bug `_account_name_source` exists to prevent.

- **FR-9: `scripts/local-seed-raw.py` MUST fail fast with an actionable error message when
  the demo registry rows are missing.** On the first `Seeder.registered_account()` call that
  returns `None` for a brand whose YAML says the platform should have an account, the script
  should print
  `frnd_os_master.account_ownership has no rows for brand <ulid> platform <name>. Run data-service/scripts/setup-local-demo.sh first.`
  and exit non-zero, rather than continuing with a fabricated `f"<alias>-acct-{brand[:8]}"`
  fallback (currently at `:322`, `:504`, `:614`, `:686`). The fallback is retained for the
  case where a brand deliberately has no registered account on that platform, but the
  distinction between "no rows exist because setup wasn't run" and "no rows exist because
  the brand doesn't use this platform" needs an escape hatch — see FR-9a.

- **FR-9a: Add a `--allow-missing-account` flag (default off) that reverts to the current
  fabricated-account-id behaviour.** For the single case a developer needs to seed a raw DB
  before the registry rows exist — e.g. wiring a new connector locally before running
  `setup-local-demo.sh` — this flag opts out of the FR-9 guard. Default off so the guard
  fires the way most developers hit it.

**Brand × platform matrix**

- **FR-10: `frndbank` is the single "full" brand and MUST carry all 9 platforms.** Brand
  ULID `01ksrm715x6ptwyjjc9gtq9vys` (from both `api/demo-ulids.json` and
  `data-service/demo-ulids.json`); platforms cover the union of
  `orchestration/domain/platforms.py::PLATFORM_TO_RAW_ALIAS`. Target: 9 platforms, 67 raw
  tables — matching `PLATFORM_RAW_TABLES` at `orchestration/domain/platforms.py:258+`
  exactly.

  ⚠️ **Amended 2026-08-31 — this FR contradicted api and api is being changed to match, not
  the FR.** Counted from `api/database/seeders/DemoWorkspaceSeeder.php:554-600`,
  `integrationDefinitions()` registers `frndbank` with **6** platforms, not 9:
  `FACEBOOK_ADS`, `FACEBOOK_PAGES`, `GOOGLE_ADS`, `GOOGLE_SHEETS_ATL`,
  `GOOGLE_SHEETS_EARNED`, `INSTAGRAM`. Missing: TikTok organic, TikTok Ads, YouTube. Across
  **all four** demo brands api covers 8 of 9 platforms — **YouTube is registered by no brand
  at all**. FR-11 and FR-12 each carry an explicit "the api tuple wins" clause; FR-10 did
  not, and simply asserted 9, so `q-brand-platform-matrix` ("one full brand carries all 9")
  and "api is source of truth" could not both hold.

  Fahmi resolved this 2026-08-31 by **widening api** rather than narrowing the matrix — see
  **FR-30**. FR-10 therefore stands at 9 platforms, and api stops being a zero-code service
  in this feature. The alternatives were rejected on the record: narrowing FR-10 to 6 would
  have abandoned full-platform coverage and left YouTube seeded for nobody; seeding raw
  beyond api's registrations for one brand would have made raw and the Postgres integration
  list deliberately disagree, which is the drift "api is source of truth" exists to prevent.

- **FR-11: `frndskincare` MUST carry the 6-platform subset used by api's
  `DemoWorkspaceSeeder`.** Brand ULID `01ksrm715zf0ejfeje5psv0kfz`. Platforms MUST match the
  tuple that `api/database/seeders/DemoWorkspaceSeeder.php` registers for `frndskincare` —
  the PRD's target arithmetic is 6 platforms / 40 raw tables. If the api tuple has changed
  since the target was recorded, the api tuple wins and the matrix arithmetic updates in the
  PR; do NOT diverge to keep the number 40.

- **FR-12: `frndairline` MUST carry the 6-platform subset used by api's
  `DemoWorkspaceSeeder`.** Brand ULID `01KT20EM84NMY4H2F492PVF9VK`. Same rule as FR-11: api
  is source of truth. Target: 6 platforms / 45 raw tables.

- **FR-13: `yourfragrance` MUST be seeded as the 4th brand with the 5-platform subset api
  already registers.** Brand ULID `01kxyx49wtvch7zxxe34mxkhbe` (from `api/demo-ulids.json`).
  Platforms MUST match `api/database/seeders/DemoWorkspaceSeeder.php:438-668`, which today
  is Instagram + TikTok organic + Facebook Pages + `gs_earned` + `gs_atl`. Target: 5
  platforms / 26 raw tables. This is a **new brand for the raw layer**, absent from
  `data-service/database/seeders/frnd_agg_marts/demo/_constants.py` — see FR-15 for the
  documented asymmetry.

- **FR-14: The api-integration rows are added for the full brand only.** Per
  `q-api-integration-rows`; do not add api integration rows for the three subset brands.

- **FR-15: Record the intentional data-service 3-brand vs api 4-brand asymmetry, with a CI
  probe rather than a consolidation.** Two acceptable forms, either satisfies the FR:
  (a) a Python assertion in `data-service`'s test suite (or a dedicated one-line script) that
  reads both `api/demo-ulids.json` and `data-service/demo-ulids.json`, computes the key
  diff, and asserts it equals exactly the set `{"yourfragrance_brand_ulid"}` — failing
  loudly if any other key drifts; or (b) a doc-block at the top of both
  `data-service/database/seeders/frnd_agg_marts/demo/_constants.py` and
  `api/app/Support/DemoUlids.php` naming the asymmetry, its cause (data-service's demo mart
  seeder covers 3 brands; api's `DemoWorkspaceSeeder` covers 4), and a link to this PRD.
  This retires the old FR-35 (`.agentic-workflows/constants/demo-ulids.json`) and its
  upstream agentic-workflows PR prerequisite; the reasoning is at
  `data-service/database/seeders/frnd_agg_marts/demo/_constants.py:1-19` (standalone
  `frnd-clickhouse-api` checkout portability).

**Reference DDL capture — data-service**

- **FR-16: Add reference DDL for the three missing platforms** (`google_ads`, `tiktok`,
  `youtube`) at `data-service/database/reference/raw_sources/<platform>.reference.sql`,
  matching the format of the six already present. **Precondition (hard):**
  the handoff §5 live-cluster findings — STAGING serviceId
  `594e5d1d-753c-400d-ab94-e9a8bf193b07`, PRODUCTION serviceId
  `64cc32f0-3a02-49f1-a88d-8967cf6e9677`, staging raw coverage 7/9 (missing `tt` organic and
  `g_ads`), production raw coverage 9/9 *(handoff-authority, re-verify before acting)* — MUST
  be re-verified before any script targets a cluster. The capture script MUST genericise
  real brand ULIDs to a placeholder token (e.g. `raw_<alias>_<brand_id>` or
  `raw_<alias>_<n>_<brand_id>` for multi-connector), and MUST NOT commit a real production
  ULID. Suggested source split, per handoff §5: `youtube` from staging;
  `tiktok` and `google_ads` from production.

- **FR-17: The generator MUST accommodate multi-connector raw DB naming.** Handoff §5 states
  that production carries `raw_<alias>_<n>_<brand>` (e.g. `raw_g_ads_2_*`, `raw_tt_5_*`) as
  a live pattern *(handoff-authority, re-verify before acting)*. The seeder itself writes to
  `raw_<alias>_<brand>` (`scripts/local-seed-raw.py:746`) which is the single-connector
  form, and the reference DDL should be captured in a form the transformers accept for both.
  If re-verification confirms multi-connector naming is live only in production, the seeder
  does not need to emit multi-connector raw DBs locally; the reference DDL still must
  parameterise `<n>` so future capture is not blocked.

- **FR-18: Do NOT "fix" the two benign registry-vs-live diffs.** `google_ads` legitimately
  lacks `custom_report_lead` (OUT-027, by design). `tiktok` carries an extra
  `creative_assets` table that is transformer-owned (`orchestration/flows/creative_assets/ddl.py:12`)
  and correctly absent from `PLATFORM_RAW_TABLES`. Any capture script that reconciles
  live DBs against the reference format MUST NOT propose adding either.

**Local runtime — `scripts/local-run-pipeline.sh` and creative_assets skip**

- **FR-19: Keep the in-process invocation at `scripts/local-run-pipeline.sh:53-56` as the
  local default trigger.** No change to the Python one-liner that calls
  `platform_pipeline_flow(workspace_id, brand_id, platform)` directly in the orchestration
  venv. This is the resolution to `q-pipeline-invocation-revisit`; NFR-2 captures the
  accepted cost. Later add-ons (Prefect API poll, Fivetran webhook body post) are owned by
  the separate `pipeline-run-visibility` feature (brief §5 Wave 0) and MUST NOT be added
  here.

- **FR-20: `scripts/local-run-pipeline.sh` MUST accept the paid and Google-Sheet platforms
  in its `PLATFORMS` argument.** Currently the default at `:24` is
  `"instagram_business,facebook_pages,tiktok,youtube"`. It should accept but not necessarily
  default to `facebook_ads,tiktok_ads,google_ads,gs_earned,gs_atl` — pass-through to
  `platform_pipeline_flow`, which already dispatches ads platforms via `ADS_PLATFORMS` at
  `orchestration/flows/platform_pipeline_flow.py:273` and organic via the else branch. The
  default remains organic-only for the fast feedback loop; the flag accepts the full nine.

- **FR-21: Preserve the localhost guard for the `clickhouse-host` Secret block at
  `scripts/local-run-pipeline.sh:41-47`.** Any change to this file MUST leave the guard
  intact — it is the last thing between a mistyped Secret and a write to Cloud staging or
  production. This is a "do not remove" FR, not "add"; called out because the file is being
  edited for FR-20.

- **FR-22: Add a local skip guard to
  `orchestration/flows/creative_assets/upload_flow.py`.** At the top of
  `creative_assets_upload_flow`, before any S3 client construction, resolve the environment
  via `integrations.clickhouse.resolve_environment()` (defined at
  `orchestration/integrations/clickhouse.py:122-133`), and when it returns `"local"` return
  `{status: "skipped_local", uploaded: 0, already_exists: 0, skipped_empty: 0, errors: 0}`
  immediately. The return shape MUST match the flow's normal terminal payload so the
  in-process caller at `orchestration/flows/platform_pipeline_flow.py` (invoked around
  `:282` for ads platforms, and via the `CREATIVE_ASSETS_PLATFORMS` gate) does not diverge
  its downstream handling. **Environment authority:** local skip fires when
  `resolve_environment() == "local"`, which today means the `environment` Secret block reads
  `"local"` and neither staging signal fires (env var `FRND_ENVIRONMENT` is not `staging` and
  the callback sniff is negative). This is consistent with the current OR at `:114-120` and
  does NOT require the future rework that `q-env-signal-authority` describes.

- **FR-23: Opt-in to real AWS from a local run requires only setting the `aws-*` Secret
  blocks.** No code path change beyond FR-22. The S3 key
  `orchestration/flows/creative_assets/upload_flow.py:598-611` already emits
  `{bucket_prefix}/frndos/<workspace_hash>/<brand_hash>/{environment}/{platform_alias}/<url_hash>{ext}`,
  which puts local uploads under a `local/` path segment when `resolve_environment()` returns
  `"local"`. Document in `orchestration/flows/creative_assets/upload_flow.py` module docstring
  that setting the `aws-*` Secret blocks locally makes uploads land at
  `s3://<bucket>/<prefix>/frndos/<...>/local/<platform>/<hash><ext>`, and that the guard from
  FR-22 short-circuits **before** the AWS client is built, so setting the Secret blocks is
  the only way to reach S3 from a local run.

- **FR-24: Do NOT touch `orchestration/integrations/aws.py`.** The MinIO substitute
  resolution is retired; the file (`:52-64` builds `boto3.client('s3', ...)` without
  `endpoint_url`) is not extended in this feature. Any diff to this file requires an
  explicit ledger row and is out of scope.

**Workspace-root and onboarding**

- **FR-25: `run-all.sh` is NOT extended to start Prefect or ClickHouse in this feature.**
  The audit brief §4.6 item 1 proposal predates the `q-pipeline-invocation-revisit`
  resolution: the in-process trigger does not require `run-all.sh` to manage Prefect. A
  future feature that adopts the Prefect-API-poll path may extend it; this feature does not.

- **FR-26: `docker-compose.dev.yml` is NOT authored in this feature.** The
  `q-clickhouse-runtime-revisit` resolution drops it entirely.
  `data-service/scripts/setup-local-demo.sh:44-59` (standalone binary) is the single
  supported provisioning path.

- **FR-27: `data-service/scripts/setup-local-demo.sh` MUST write `prefect_setup` and
  `ch_local` into `.onboard-state.json` on successful completion.** Verified 2026-08-31:
  neither key exists in `.onboard-state.json` on this workspace today; the file records
  `status: "completed"` with all 14 `steps.*` completed (`github_access`, `questionnaire`,
  `prerequisites`, `model_access`, `clone_repos`, `install_deps`, `env_files`, `db_setup`,
  `run_all_sh`, `docs_structure`, `editor_tooling`, `loki_install` = skipped,
  `community_skills` = blocked, `mcp_servers`, `verify`). The two new keys are **additive
  and top-level, alongside `steps`**, and MUST NOT disturb the existing shape — no
  re-serialisation of unrelated keys, no removal or reordering, no writes inside
  `steps.*`. Semantics:
    - `prefect_setup: "completed"` is set once the local Prefect profile is confirmed
      present at `~/.prefect/profiles.toml` and reachable at `http://127.0.0.1:4200/api`
      (or a `curl -s` HEAD to the profile's `api_url` — profile-agnostic to a developer
      who has renamed it).
    - `ch_local: "completed"` is set once the standalone binary at
      `$CH_LOCAL_DIR/clickhouse` (default `~/clickhouse-local/clickhouse`) is executable
      AND the health probe already in the setup script at
      `data-service/scripts/setup-local-demo.sh:63-70` passes (server answers on `:8123`
      with `SELECT 1`).
  Both writes MUST be **idempotent** (re-running the script updates the two keys in place;
  no duplicate keys, no growing JSON) and **non-fatal** — a failure to update onboarding
  state MUST NOT fail the demo setup. Use `warn "…"` (already defined at the top of
  `data-service/scripts/setup-local-demo.sh`) and continue. Implementation should use
  `python3 -c` with `json.load` / `json.dump` (indent=4, matching the existing formatting)
  rather than `jq`, so the setup script gains no new tool dependency. NFR-11 records the
  cross-boundary write cost.

- **FR-30: `api/database/seeders/DemoWorkspaceSeeder.php` MUST register `frndbank` with all
  nine platforms.** `integrationDefinitions()` at `:554-600` today emits 6 tuples for
  `frndbank`; this FR adds three — TikTok organic, TikTok Ads and YouTube — so that FR-10's
  9-platform matrix is true against api rather than in spite of it. Each new tuple follows
  the existing shape exactly: `brand_id` from `DemoUlids::frndbankBrandUlid()`, `brand_slug`
  `'frndbank'`, the matching `BrandIntegration::PLATFORM_*` constant, and an `account_name`
  in the established voice (the existing rows read `'frndBank Facebook'`, `'@frndbank'`,
  `'frndBank Ads Account'`, `'frndBank Google Ads'`).

  Four constraints:

  1. **`frndskincare`, `frndairline` and `yourfragrance` are NOT widened.** Their tuples are
     already correct — 6, 6 and 5 respectively, verified 2026-08-31 against FR-11, FR-12 and
     FR-13. Only `frndbank` changes.
  2. **No new constant is needed — verified 2026-08-31.**
     `BrandIntegration::PLATFORM_YOUTUBE = 'youtube_analytics'` already exists at
     `api/app/Models/BrandIntegration.php:92`, alongside `PLATFORM_TIKTOK_ORGANIC` (`:90`)
     and `PLATFORM_TIKTOK_ADS` (`:96`). `mediaTypeForPlatform()` at `:346-365` needs no new
     arm either: YouTube is in none of the PAID / EARNED / ATL / BUSINESS lists, so it falls
     through to `MEDIA_TYPE_OWNED`, which is correct. This FR is three data rows, nothing
     structural.
  3. **The derived ids stay derived.** `:275` builds `demo_{brand_slug}_{platform}` and
     `:299-300` builds `demo_{brand_slug}_account`; the new tuples must not hardcode either.
  4. **This does not create ClickHouse `account_ownership` rows** — see the risk note below.

  This FR is why api's service PRD and track file, which were written and committed on
  2026-08-31 declaring api a zero-code service, are superseded. api now carries code and
  moves in the merge order accordingly.

- **FR-30b: The seeder MUST map api's platform vocabulary onto orchestration's.** FR-11,
  FR-12 and FR-13 say the raw seeder's platforms "MUST match" api's tuples, which is
  ambiguous as written: **four of the nine names differ** between
  `api/app/Models/BrandIntegration.php:86-102` and
  `orchestration/domain/platforms.py::PLATFORM_TO_RAW_ALIAS:39-49`. Counted 2026-08-31:

  | api `BrandIntegration::PLATFORM_*` | orchestration key | raw alias | same? |
  |---|---|---|---|
  | `instagram_business` | `instagram_business` | `ig` | yes |
  | `facebook_pages` | `facebook_pages` | `fb` | yes |
  | `facebook_ads` | `facebook_ads` | `fb_ads` | yes |
  | `tiktok_ads` | `tiktok_ads` | `tt_ads` | yes |
  | `google_ads` | `google_ads` | `g_ads` | yes |
  | `tiktok_organic` | `tiktok` | `tt` | **no** |
  | `youtube_analytics` | `youtube` | `yt` | **no** |
  | `google_sheets_earned` | `gs_earned` | `gs_earned` | **no** |
  | `google_sheets_atl` | `gs_atl` | `gs_atl` | **no** |

  The mapping MUST live in one named place in `scripts/local-seed-raw.py` — a single dict
  beside the existing `PLATFORMS` map at `:54-59`, not four inline conditionals — and a test
  MUST assert the mapping is total in both directions: every
  `PLATFORM_TO_RAW_ALIAS` key resolves to exactly one api constant and vice versa. Without
  that assertion, adding a tenth platform to either side silently drops a brand's raw DB,
  and an absent raw DB reads downstream as an empty mart, which looks like a pipeline bug
  rather than a missing fixture — the same failure mode FR-28's completeness assertion
  exists to prevent on the orchestration side.

- **FR-30a: Record that widening api does not by itself satisfy `Seeder.registered_account()`.**
  `frnd_os_master.account_ownership` is **not** derived from api. It is derived by
  `data-service/database/seeders/frnd_agg_marts/demo/seed_demo.py:635-641` from
  `frnd_agg_marts.paid_ads_performance` and at `:651-658` from
  `frnd_agg_marts.social_content_performance` — and those mart rows are themselves **copied
  from real source tenants** (`copy_mart_for_brand` at `:241`, source filter at `:532-546`;
  the module header at `:56-57` maps `frndbank` to source `simpati`). So whether frndbank
  gains TikTok and YouTube rows in `account_ownership` depends on whether the *source*
  tenant carries those channels, which is a runtime fact and was **not verifiable when this
  was written** (local ClickHouse was stopped).

  Consequence to check on the first run against a live local stack: if the source tenant has
  no TikTok/YouTube channels, `Seeder.registered_account()` returns `None` for
  `frndbank`/`tt` and `frndbank`/`yt`, and **FR-9's fail-fast guard fires** telling the
  developer to run `setup-local-demo.sh` — which they will already have run. Two acceptable
  outcomes, decided at that point with the measurement in hand: use FR-9a's
  `--allow-missing-account` for those two platform legs, or widen the demo mart copy so the
  channels exist. Do not pre-build either; measure first.

### Non-Functional Requirements

- **NFR-1: Runtime target.** A full pass — `setup-local-demo.sh` (one-time) → nine platforms
  seeded on `frndbank` at `--days 30` → `local-run-pipeline.sh frndAgency frndbank <all
  nine>` → mart sanity output — completes in under 10 minutes on Fahmi's MacBook Pro
  (baseline reference machine). The seeder alone must complete in under 2 minutes per brand
  at the default `--posts 40 --days 30`. Numbers established by the first PR against a
  running local stack; adjust in a follow-up if measurement disagrees.

- **NFR-2: Local trigger has no production-path fidelity — accepted cost.** The in-process
  invocation at `scripts/local-run-pipeline.sh:53-56` does not exercise the
  Fivetran-webhook → data-service tenant resolution → Prefect deployment trigger → Prefect
  worker → state-hook → data-service webhook path that production runs through, and local
  runs do NOT appear in the Prefect UI. This is the accepted cost of the
  `q-pipeline-invocation-revisit` resolution; the alternative paths (Prefect API poll,
  webhook body POST) remain reachable and are owned by the separate `pipeline-run-visibility`
  feature (brief §5 Wave 0).

- **NFR-3: Localhost guards MUST NOT be weakened.**
  - `scripts/local-seed-raw.py:789-791` refuses non-`localhost`/`127.0.0.1` hosts.
  - `scripts/local-run-pipeline.sh:41-47` refuses to run unless the `clickhouse-host` Secret
    block reads `localhost`/`127.0.0.1`.
  - The `local` Prefect profile at `~/.prefect/profiles.toml` MUST remain the target of
    `PREFECT_PROFILE=local`, and no PR from this feature MAY invoke `prefect profile use` or
    `prefect config set` (both denied globally in `.claude/settings.json`).
  - The runner MUST NOT pass `callback_url` to `platform_pipeline_flow` — the current call
    at `:54-56` does not, and preserving that means the state hook returns before posting to
    any `/api/v1/webhook/prefect` endpoint.

- **NFR-4: Standalone-binary-only provisioning.** ClickHouse comes from the binary at
  `$CH_LOCAL_DIR` downloaded by `data-service/scripts/setup-local-demo.sh:44-59`. No PR from
  this feature may add or re-introduce `docker-compose.dev.yml`, any `docker`-based
  provisioning documentation, or a rival startup script that binds `:8123`. Windows users
  use WSL or the native binary; explicit Windows CI is not required in this feature.

- **NFR-5: Rolling date window is both a size cap and a freshness knob.** The default
  `--days 30` (FR-6, FR-7) MUST result in `staging_date_cutoff` (production value
  `2025-01-01`) never dropping any row of a fresh seed run. The 60-day cap keeps
  `entities × days` bounded so the seeder stays under the NFR-1 runtime target.

- **NFR-6: Fixture must not carry real production data.** Every brand ULID in a seeded raw
  DB name is one of `frnd_agency_workspace_ulid`, `frndbank_brand_ulid`,
  `frndskincare_brand_ulid`, `frndairline_brand_ulid`, or `yourfragrance_brand_ulid` from
  the two `demo-ulids.json` files. Reference DDL capture (FR-16) MUST parameterise real
  ULIDs to a placeholder token before commit; a CI grep for known production ULID patterns
  in `data-service/database/reference/raw_sources/` MUST pass — and is a required part of
  FR-16's PR.

- **NFR-7: Declaration-driven, not hand-written.** The seeder derives table shape from
  `orchestration/config_handover/*.yaml` (via `load_contract()` at
  `scripts/local-seed-raw.py:169-189`) and column type from name-based inference at
  `_ch_type()` (`:106-124`) plus per-column `TYPE_OVERRIDES` (`:77-91`) and per-(alias,
  table) `REQUIRED_COLUMNS` (`:136-166`). The five new platforms MUST use the same three
  inputs; no PR may hand-write a table schema out-of-band from these declarations. A new
  connector added to `PLATFORM_TO_RAW_ALIAS` becomes a CI failure — see FR-28.

- **NFR-8: `insert()` and `_ch_type()` are frozen in this feature.** Freezing them is the
  guarantee that the four existing organic platforms do not regress under the five-platform
  extension. Any change requires an explicit ledger row and is out of scope.

- **NFR-9: The seeder MUST NOT touch `staging_<workspace_id>` or `frnd_agg_marts` row data.**
  `staging_*` is a build product — `orchestration/integrations/clickhouse.py:174` defines
  `ensure_database` and the transform helpers call it; `orchestration/tasks/transform_helpers.py`
  around `:553` creates staging DBs via `ensure_staging_db`. Pre-seeding rows into staging
  manufactures exactly the drift the (separate) `staging-schema-versioning` feature exists
  to eliminate. Pre-seeding `frnd_agg_marts` rows would mean the fixture proves nothing
  about the pipeline. DDL for `frnd_agg_marts` is applied by
  `data-service/scripts/setup-local-demo.sh` and by orchestration's inline Alembic in
  `platform_pipeline_flow` (per `orchestration/tasks/migrate_marts.py`); the seeder does
  neither.

- **NFR-10: No changes to `prefect.frndos.com`.** AGENTS.md hard rule 8. No PR from this
  feature may create, register or mutate a deployment on the shared Prefect server, even
  transiently for testing. The local Prefect server at `127.0.0.1:4200` is the only trigger
  target.

- **NFR-11: Cross-boundary write, accepted cost.** FR-27 has
  `data-service/scripts/setup-local-demo.sh` write to `.onboard-state.json`, which is a
  workspace-root file owned by the onboarding / agentic-workflows domain rather than by
  data-service. Accepted so onboarding state stays true after a demo setup run without
  requiring a separate onboarding invocation, at the cost that a future search for
  "what mutates `.onboard-state.json`" no longer terminates at the onboarding scripts —
  a data-service script also touches it. Mitigated by three things, none of which remove
  the cost: (a) the write is idempotent and non-fatal (FR-27), so a maintainer removing
  it does not break the file's other consumers; (b) the two keys use the same
  `<name>: "completed"` shape onboarding's own `steps.*` keys use, so their intent is
  self-evident on read; (c) a header comment in `data-service/scripts/setup-local-demo.sh`
  names the file it touches, the two keys it writes, and points at this NFR — so anyone
  reading top-down finds the boundary cross before the code that performs it.

### Declaration-driven completeness (CI)

- **FR-28: Add a CI assertion that every alias in
  `orchestration/domain/platforms.py::PLATFORM_TO_RAW_ALIAS` has a corresponding entry in
  `scripts/local-seed-raw.py::PLATFORMS`.** Failure message names the missing alias. This is
  the mechanism NFR-7 relies on to catch a tenth connector being added without a fixture.
  Suggested location: a workspace-root test invoked from CI, or a `pytest` in
  `orchestration/tests/` that imports the seeder module — implementation form is at the PR
  author's discretion, as long as the assertion runs in the CI pipeline that gates PRs
  touching either file.

### Legacy artefact — `dummy_connector/` deprecation banner

- **FR-29: Add a `SUPERSEDED` banner to
  `data-service/database/seeders/dummy_connector/000_seed_dummy_connector.py` and to
  `data-service/database/seeders/dummy_connector/README.md`.** The file keeps working; the
  banner records that its owning role has moved. Both files exist on this workspace and
  today carry no supersede note (verified 2026-08-31). Three constraints, each load-bearing:

  1. **The file MUST NOT be removed in this PR.** Its `frnd_os_master.workspaces` /
     `brands` / `connectors` / `connector_syncs` writes at
     `data-service/database/seeders/dummy_connector/000_seed_dummy_connector.py:228-243`
     are duplicated nowhere else — `scripts/local-seed-raw.py` only **reads**
     `frnd_os_master.account_ownership` at `:238-242` and does NOT write registry rows.
     Removing this file breaks the bootstrap ordering FR-8 and FR-9 depend on, because
     the demo bootstrap chain is
     `data-service/scripts/setup-local-demo.sh` (which calls `seed_demo.py` for the three
     demo brands' registry rows) → `dummy_connector/000_seed_dummy_connector.py` (for the
     `01jq…fbads` dummy tenant's registry rows) → `scripts/local-seed-raw.py`.
     Deprecation is scoped to the banner; removal is a separate follow-up feature.
  2. **What supersedes it and for what.** Banner MUST name `scripts/local-seed-raw.py` as
     successor and MUST contrast scope explicitly:
     `dummy_connector/000_seed_dummy_connector.py:54` hardcodes `PLATFORM = "facebook_ads"`
     and stands up one raw DB `raw_fb_ads_<01jq…fbads>` for the dummy tenant. After this
     feature, `scripts/local-seed-raw.py` covers all nine platforms (FR-1) across four
     demo brands (FR-10 to FR-13); on nine of nine platform × dummy-tenant combinations,
     `local-seed-raw.py` is the same or larger shape and is declaration-driven from
     `orchestration/config_handover/*.yaml` (`load_contract()` at
     `scripts/local-seed-raw.py:169-189`) rather than the hardcoded `RAW_TABLES_DDL` at
     `dummy_connector/000_seed_dummy_connector.py:1-100`-ish.
  3. **Wording follows the ledger protocol.** `.claude/rules/request-integrity.md` "Banner
     the corpse" prescribes the shape for a superseded artefact. The exact banner text,
     adapted so "kept" is unambiguous (the file is intentionally live, not history-only):

     ```
     ⛔ SUPERSEDED (2026-08-31) by scripts/local-seed-raw.py.

     KEPT — this file's frnd_os_master.workspaces/brands/connectors/connector_syncs
     writes at :228-243 are still the dummy-tenant leg of the local bootstrap ordering
     (see docs/prd/local-pipeline-e2e.md FR-8, FR-9). Nothing else in the workspace
     writes those rows for the dummy tenant.

     Scope contrast: this file covers ONLY facebook_ads for the dummy tenant
     01jq00000000000000000fbads. scripts/local-seed-raw.py covers all nine platforms
     across the four demo brands (frndbank, frndskincare, frndairline, yourfragrance)
     and is declaration-driven from orchestration/config_handover/*.yaml.

     Do NOT extend this file for new platforms; extend scripts/local-seed-raw.py
     instead. Removal is deferred to a follow-up feature that also relocates the
     dummy-tenant registry writes.
     ```

     In the Python module the banner sits at the top of the module docstring
     (`data-service/database/seeders/dummy_connector/000_seed_dummy_connector.py:1-30`
     already holds the module docstring — the banner prepends). In `README.md` it sits
     above the existing `# `dummy_connector/` — local end-to-end connector fixture`
     heading.

## Service Breakdown

### API (`api/`)

⚠️ **Amended 2026-08-31 — api is no longer a zero-code service.** This section previously
read "Read-only touch. No PHP code changes." That was accurate against the PRD as first
written and is **superseded** by FR-30, after the count at
`api/database/seeders/DemoWorkspaceSeeder.php:554-600` showed `frndbank` registered with 6
platforms where FR-10 requires 9.

**One code change: FR-30** — three tuples added to `integrationDefinitions()` so `frndbank`
carries TikTok organic, TikTok Ads and YouTube, plus a `PLATFORM_YOUTUBE` constant and its
`mediaTypeForPlatform()` arm if they do not already exist. Nothing else in api changes.

- **FR-11 / FR-12 / FR-13 rely on api's `DemoWorkspaceSeeder`** as the source of truth for
  the per-brand platform tuples. The seeder must NOT be edited in this feature to widen the
  matrix; conversely, if `DemoWorkspaceSeeder.php` already changes elsewhere before
  implementation, the raw seeder follows.
- **FR-15** may add a doc-block comment to `api/app/Support/DemoUlids.php` naming the
  intentional 3-brand vs 4-brand asymmetry. Comment-only; no method changes.
- **Base branch:** `develop` (per `data-service/scripts/setup-local-demo.sh` and workspace
  convention). Currently 560 commits behind origin; splitter brings the base current before
  branching.

### Frontend (`web/`)

Out of scope. Web consumes the marts this feature produces but requires no change. Base
branch `develop`; 422 behind origin.

### AI Service (`ai-service/`)

Out of scope. Not touched.

### Data Service (`data-service/`)

- **FR-8** — mandatory bootstrap ordering, documented in header comments in
  `data-service/scripts/setup-local-demo.sh` too if a natural place exists (a single line
  pointing forward to `scripts/local-seed-raw.py` is sufficient).
- **FR-15** — CI probe implementation. Fahmi selected `ci_probe` for the FR-15 form
  (`q-yourfragrance-data-service-asymmetry-form` = `ci_probe`), so this becomes a Python
  assertion in `data-service`'s test suite that reads both `demo-ulids.json` files and
  asserts the key-set diff equals exactly `{"yourfragrance_brand_ulid"}`.
- **FR-16 / FR-17 / FR-18** — reference DDL capture; three new files at
  `data-service/database/reference/raw_sources/{google_ads,tiktok,youtube}.reference.sql`.
  Precondition-gated on re-verifying handoff §5.
- **FR-27** — `.onboard-state.json` write from `data-service/scripts/setup-local-demo.sh`
  (see FR-27 for shape, idempotence, non-fatal requirement; NFR-11 for cross-boundary
  cost).
- **FR-29** — `SUPERSEDED` banner on
  `data-service/database/seeders/dummy_connector/000_seed_dummy_connector.py` and its
  co-located `README.md`. **File keeps working** — its registry writes at `:228-243`
  remain the dummy-tenant leg of the bootstrap ordering FR-8 / FR-9 depend on.
- **Base branch:** `development`. Currently 17 behind origin; splitter brings current before
  branching. The `apply_dir()` word-splitting fix that
  `setup-local-demo.sh:85` needs for paths containing a space is already present in the
  merged branch this workspace runs.

### Orchestration (`orchestration/`)

- **FR-22** — local skip guard at the top of
  `orchestration/flows/creative_assets/upload_flow.py`, keying on
  `integrations.clickhouse.resolve_environment() == "local"`.
- **FR-23** — module-docstring documentation of the opt-in path (real AWS via existing
  `aws-*` Secret blocks; no code change beyond FR-22).
- **FR-24** — `orchestration/integrations/aws.py` MUST NOT be touched.
- **`orchestration/integrations/clickhouse.py` is NOT changed.** The `q-env-signal-authority`
  resolution ("environment Secret block is authoritative") describes future direction and is
  owned by `env-cost-policy` (brief §5 Wave 2). The current OR at `:114-120` remains.
- **`orchestration/flows/platform_pipeline_flow.py` is NOT changed.** Its inline call around
  `:282` continues to invoke `creative_assets_upload_flow`; the flow itself early-returns
  under FR-22 when local.
- **Base branch:** `staging`. Currently 4 behind origin; splitter brings current before
  branching.

### Workspace-root (`scripts/`, root config)

Home to the two scripts that are the majority of this feature's diff.

- **FR-1 through FR-7, FR-9, FR-9a** — `scripts/local-seed-raw.py`.
- **FR-8** — header docstrings on both `scripts/local-seed-raw.py` and
  `scripts/local-run-pipeline.sh`.
- **FR-19, FR-20, FR-21** — `scripts/local-run-pipeline.sh`.
- **FR-25, FR-26** — `run-all.sh` and `docker-compose.dev.yml` are NOT edited /
  NOT created.
- **FR-28** — CI assertion.
- No new files under `scripts/` (no `bootstrap-pipeline.sh`, no rivals).

## UI/UX

Not applicable — this is a backend / local-tooling feature. No screens, no mock data notes.

## Data Model

### New Tables

None owned by this feature. The seeder creates per-brand raw databases
`raw_<alias>_<brand>` at runtime with `CREATE TABLE IF NOT EXISTS` per
`scripts/local-seed-raw.py:280-283`; these are fixture tables in a local ClickHouse and are
not "new tables" in the migration sense. Their schema is derived from
`orchestration/config_handover/*.yaml` allow-lists, and their canonical shape is the
reference DDL under `data-service/database/reference/raw_sources/` (six existing, three
added by FR-16).

### Modified Tables

None. The seeder MUST NOT touch `staging_<workspace_id>` (a build product per NFR-9), or
`frnd_agg_marts` row data (DDL only, applied by
`data-service/scripts/setup-local-demo.sh` and by orchestration's Alembic).

## API Endpoints

None. This feature adds no HTTP endpoints and modifies none.

## Acceptance Criteria

- [ ] **AC-1:** `python3 scripts/local-seed-raw.py --list` prints all nine platforms with
      their contract table counts (currently prints four).
- [ ] **AC-2:** `python3 scripts/local-seed-raw.py --brand 01ksrm715x6ptwyjjc9gtq9vys` (the
      `frndbank` ULID) seeds all 67 tables across the 9 raw databases (`raw_ig_frndbank...`,
      `raw_fb_frndbank...`, ..., `raw_gs_atl_frndbank...`) after
      `data-service/scripts/setup-local-demo.sh` has been run, at the default `--days 30 --posts 40`
      settings, in under 2 minutes.
- [ ] **AC-3:** The same command run for `frndskincare`, `frndairline` and `yourfragrance`
      seeds exactly the subset registered in `api/database/seeders/DemoWorkspaceSeeder.php`
      for each brand (FR-11, FR-12, FR-13). Total across four brands: 26 raw databases and
      178 raw tables. If the api tuple changes the target arithmetic follows.
- [ ] **AC-4:** Every fact-table row seeded by `local-seed-raw.py` at the default `--days
      30` has an event timestamp within the last 30 days from the moment the script runs, and
      no row is dropped by `staging_date_cutoff` (`2025-01-01` in production; effectively
      any date after early 2025).
- [ ] **AC-5:** `scripts/local-seed-raw.py` invoked before
      `data-service/scripts/setup-local-demo.sh` exits non-zero on the first missing
      registry row and prints the actionable message from FR-9, unless
      `--allow-missing-account` is passed (FR-9a).
- [ ] **AC-6:** `scripts/local-run-pipeline.sh frndAgency 01ksrm715x6ptwyjjc9gtq9vys`
      (default four organic platforms) completes with non-zero row counts in
      `frnd_agg_marts.social_content_performance FINAL` for every channel it exercises, and
      `impossible` (`retained_views_3s > video_views`) reads 0 for every channel — the
      invariant `scripts/local-run-pipeline.sh:75-86` already checks.
- [ ] **AC-7:** `scripts/local-run-pipeline.sh frndAgency 01ksrm715x6ptwyjjc9gtq9vys
      facebook_ads,tiktok_ads,google_ads,gs_earned,gs_atl` runs the paid + Google-Sheet
      chain successfully (FR-20) and populates
      `frnd_agg_marts.paid_ads_performance{,_age_gender,_region}`,
      `frnd_agg_marts.earned_content_data`, `frnd_agg_marts.atl_media_performance` with
      non-zero rows.
- [ ] **AC-8:** During any local run, `orchestration/flows/creative_assets/upload_flow.py`
      returns `{status: "skipped_local", ...}` and does NOT construct an S3 client, when
      `resolve_environment()` returns `"local"` (FR-22). Opting in via real `aws-*` Secret
      blocks produces S3 keys under the `local/` prefix (FR-23).
- [ ] **AC-9:** `scripts/local-run-pipeline.sh` at any point during the run cannot reach
      `prefect.frndos.com` (network path unused) or Cloud ClickHouse (the localhost guard at
      `:41-47` refuses); the runner passes no `callback_url` (NFR-3).
- [ ] **AC-10:** Adding a hypothetical tenth alias to
      `orchestration/domain/platforms.py::PLATFORM_TO_RAW_ALIAS` without a corresponding
      entry in `scripts/local-seed-raw.py::PLATFORMS` fails the CI assertion added by FR-28.
- [ ] **AC-11:** `data-service/database/reference/raw_sources/` gains
      `google_ads.reference.sql`, `tiktok.reference.sql`, `youtube.reference.sql` (FR-16),
      each in the format of the six existing files, each with brand ULIDs genericised and
      no real production ULID present. A CI grep for known production-ULID patterns in that
      directory passes (NFR-6). *Precondition-gated: only completed once handoff §5's
      live-cluster findings have been re-verified — this session cannot.*
- [ ] **AC-12:** The `_constants.py` docstring and/or a CI probe records the intentional
      `demo-ulids.json` asymmetry (FR-15) so future drift beyond `yourfragrance_brand_ulid`
      would fail loudly.
- [ ] **AC-13:** No file under `orchestration/integrations/aws.py` is modified (NFR-8 for
      that file; FR-24). No `docker-compose.dev.yml` is added anywhere in the workspace
      (FR-26). No file under `orchestration/integrations/clickhouse.py` is modified
      (assumption re-stated: env-signal authority is not this feature's scope).
- [ ] **AC-14:** `scripts/local-seed-raw.py:106` (`_ch_type`) and `:286` (`insert`) are
      byte-identical to their state at `0505be8` (NFR-8).
- [ ] **AC-15:** After a fresh run of `data-service/scripts/setup-local-demo.sh` on a
      workspace whose `.onboard-state.json` lacks the keys, the file gains
      `"prefect_setup": "completed"` and `"ch_local": "completed"` at the top level (not
      inside `steps`), all other keys stay byte-identical to before the run except for the
      appended pair, and re-running the script does not add duplicate entries (FR-27). If
      either probe fails, the script logs `[warn]` and completes with exit 0 anyway
      (NFR-11 mitigation, FR-27 non-fatal clause).
- [ ] **AC-16:** `data-service/database/seeders/dummy_connector/000_seed_dummy_connector.py`
      module docstring and the co-located `README.md` both open with the `⛔ SUPERSEDED`
      banner text specified in FR-29. The file's line count grows by the banner size only —
      the `main()` entrypoint and the registry-write block at `:228-243` remain
      byte-identical. Running the file still produces the `raw_fb_ads_<dummy>` DB and the
      four `frnd_os_master` registry rows.

## Open Questions

All six were resolved 2026-08-31. Four match the assumed answers; two are Fahmi overrides
that rewrote requirements (FR-27 and FR-29 above). This section is kept for the record so a
later reader can trace each requirement back to the choice behind it, not to signal
outstanding blockers.

- [x] **q-reference-ddl-capture-preconditions** = **`re_verify_before_capture`** (matches
      assumed). FR-16 is precondition-gated: no capture script may target a cluster until
      handoff §5's staging/production service ids and raw-coverage figures are re-verified
      in an interactive session with `prefect-frnd` / `prefect-alva` / `clickhouse-remote`
      authenticated, and the re-verified figures are recorded in the capture script's
      header. Cost: FR-16 cannot land until an interactive session runs the re-verification
      — this session cannot. Rationale carried:
      `docs/briefs/2026-08-30-handoff-local-pipeline-e2e.md:170-171`
      (*"must be re-checked before any capture script targets a cluster"*).

- [x] **q-multi-connector-naming-scope** = **`ref_ddl_only`** (matches assumed). FR-17
      requires that the *reference DDL* parameterise `<n>` for `raw_<alias>_<n>_<brand>`,
      but the *seeder* keeps emitting single-connector `raw_<alias>_<brand>` as today
      (`scripts/local-seed-raw.py:746`). See **Resolved history — multi-connector detour**
      and **Known latent issue — `raw_database` deprecation path** below.

- [x] **q-yourfragrance-data-service-asymmetry-form** = **`ci_probe`** (matches assumed).
      FR-15 becomes a Python assertion in `data-service/tests/` that reads both
      `demo-ulids.json` files and asserts the key-set difference is exactly
      `{"yourfragrance_brand_ulid"}`. Cost: a new test file in `data-service` that reads a
      workspace-root path (`../api/demo-ulids.json`) — mitigated by the same test also
      reading `data-service/demo-ulids.json` from its own repo, so a data-service standalone
      checkout without `../api/` degrades gracefully (skip with a clear message rather than
      fail). Rationale carried: doc-block-only silently rots the moment `api/demo-ulids.json`
      gains a fifth key, per `data-service/database/seeders/frnd_agg_marts/demo/_constants.py:1-19`.

- [x] **q-rolling-window-default** = **`days_30`** (matches assumed). FR-6 and FR-7 default
      the `--days` flag to 30, capped at 60. Rationale carried: brief §4.4's `entities × days`
      cap; web's default 28-day range covered with room; 60 available via the flag.

- [x] **q-onboarding-state-scope** = **`close_in_setup_local_demo`** *(OVERRIDE — was assumed
      `out_of_scope`)*. Rewrote what was a "not closed" note into **FR-27** — the write is
      idempotent and non-fatal — and added **NFR-11** to record the accepted cross-boundary
      cost (a data-service script now writes a workspace-root file). Two things the override
      hinges on that a later reader should not have to re-derive: the two new keys are
      **top-level and additive** (they do not sit inside `steps.*`, and no other key
      reshapes on write), and a failure to update the state file MUST NOT fail the demo
      setup — `[warn]` and continue.

- [x] **q-dummy-connector-deprecation-scope** = **`deprecate_banner`** *(OVERRIDE — was
      assumed `follow_up`)*. Rewrote the "not touched" note into **FR-29** — banner on the
      module docstring and on `README.md`, wording adapted from `.claude/rules/request-integrity.md`
      so "kept" is unambiguous (the file is intentionally live, not history-only). The three
      constraints in FR-29 are load-bearing and any implementation MUST honour all three: no
      removal in this PR (the `frnd_os_master` registry writes at `:228-243` are duplicated
      nowhere else and are the dummy-tenant leg of the bootstrap chain FR-8/FR-9 depend on);
      supersede text names `scripts/local-seed-raw.py` and contrasts scope (`facebook_ads`
      for the dummy tenant vs 9 platforms × 4 demo brands); banner wording follows the
      ledger protocol.

### Resolved history — multi-connector detour (worth carrying)

`q-multi-connector-naming-scope` landed as `ref_ddl_only`, but survived a detour: an
intermediate answer asked for seeded rows on doubled raw DBs (`raw_<alias>_<n>_<brand>`)
across all 9 platforms. That was withdrawn once the ambiguity was surfaced — the word
"connector" had been used for two unrelated things: the `dummy_connector/` **folder** (a
seeder module), versus a Fivetran **second instance** of the same platform for one brand.
The doubled variant would have taken the fixture from 26 raw DBs / 178 tables to
approximately 52 / 356 and doubled pipeline invocations per bootstrap, without exercising
any code path that would fail single-instance. Two facts found while checking it, both
worth carrying as evidence even though no requirement changes:

- **Multi-connector is supported end to end today**, but by invoking
  `platform_pipeline_flow` **once per raw database** with `raw_database` passed explicitly
  (`orchestration/tasks/transform_tasks.py:71-84`), not by one run unioning them.
  `orchestration/domain/platforms.py:145-147` builds a single un-indexed name
  (`raw_database(platform, brand_id) -> f"raw_{resolve_raw_alias(platform)}_{brand_id}"`);
  `orchestration/tasks/load_marts.py:74-81` unions instances via
  `SELECT name FROM system.databases WHERE name = {b:String} OR match(name, {re:String})`
  with `re = "^raw_<alias>_[0-9]+_<brand_id>$"`, but only when the platform sits in
  `RAW_RESIDENT_REGISTRY_PLATFORMS`; `orchestration/domain/platforms.py:149-169`
  `raw_source_index()` exists for `gs_earned` as a ReplacingMergeTree ORDER BY tiebreaker,
  because two sheets' Fivetran `_row` indices both restart at 0 and would collide without
  it.
- **Local ClickHouse currently holds zero `raw_<alias>_<n>_<brand>` databases.** Handoff §5
  observed the pattern live in production only; on this machine every raw DB on disk is
  single-instance. That is what makes `ref_ddl_only` sufficient — the transformers and mart
  loaders resolve multi-connector already, so nothing in the local loop needs a doubled
  fixture to exercise the code path.

### Known latent issue — `raw_database` deprecation path (do NOT fix here)

Ranked last because it is discovered evidence, not a requirement of this feature.

`scripts/local-run-pipeline.sh:53-56` invokes `platform_pipeline_flow(workspace_id,
brand_id, platform)` without passing `raw_database`. Downstream at
`orchestration/tasks/transform_tasks.py:71-84`, the flow takes the branch that logs
verbatim:

> `raw_database param not provided; falling back to compute (deprecated path) for platform=%s brand=%s → %s`

Every local run today emits that log line, once per platform, on the exact runner path this
feature edits (FR-19, FR-20). **This is NOT fixed in this feature** — the fix would either
compute `raw_database = raw_database(platform, brand_id)` in the runner and forward it, or
touch `orchestration/tasks/transform_tasks.py` to remove the deprecated path. Both are out
of scope: the multi-connector question is closed (`ref_ddl_only`), no local test case needs
multi-connector, and touching `transform_tasks.py` for a runner change violates NFR-8's
spirit (freeze what you don't need). Recorded here so it does not get lost — a future
`pipeline-run-visibility` feature or a follow-up to `q-dummy-connector-deprecation-scope`
is the natural home.
