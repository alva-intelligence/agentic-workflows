---
title: Local pipeline end-to-end — workspace-root
slug: local-pipeline-e2e
service: workspace-root
author: fahmi.zuhdi@alva.digital
created: 2026-08-31
status: draft
type: improvement
upstream_prd: docs/prd/local-pipeline-e2e.md
base_branch: (workspace-root is NOT branched — see Bootstrap boundary below)
target_branch: (none — commits land on feat/fahmi/data-agentic-setup by convention)
merge_order: 4 of 4 (workspace-root ships last; depends on orchestration #1, api #2 and data-service #3)  # renumbered 2026-08-31: api gained code (FR-30)  # renumbered 2026-08-31: api gained code (FR-30), now 2 of 4
---

# Local pipeline end-to-end — workspace-root

## Bootstrap boundary — do NOT branch this repo

The workspace root is the `agentic-workflows` checkout itself, currently on
`feat/fahmi/data-agentic-setup` with three unpushed commits carrying the
`W12`/`W13` ledger rows, both briefs and the main PRD. **This split created no
branch here.** Do not check out, branch, stash, reset, or commit on the
workspace root outside `feat/fahmi/data-agentic-setup`. The main PRD
`docs/prd/local-pipeline-e2e.md` is the split source and must not be
overwritten; this file is deliberately named `local-pipeline-e2e.workspace-root.md`
to avoid collision.

## Overview

Workspace-root owns the largest share of the diff: extending
`scripts/local-seed-raw.py` from 4 to 9 platforms (organic-only today; paid and
Google-Sheet shapes still absent), turning the hardcoded seed date into a
rolling window, calling out the bootstrap-ordering trap that fails silently
when `local-seed-raw.py` runs before `data-service/scripts/setup-local-demo.sh`,
and accepting the paid/Google-Sheet platforms in `scripts/local-run-pipeline.sh`
while leaving its localhost guard and in-process trigger untouched. It also
adds a CI assertion that catches a tenth alias landing in
`orchestration/domain/platforms.py::PLATFORM_TO_RAW_ALIAS` without a matching
`PLATFORMS` entry in the seeder.

The three brand-matrix FRs (FR-10/11/12/13) and the api-integration-rows FR
(FR-14) are executed here (via `--brand`), but their tuple contents are read
from `api/database/seeders/DemoWorkspaceSeeder.php` — do not diverge to keep a
target row count.

## Requirements owned by workspace-root

| Requirement | Scope |
|---|---|
| **FR-1** | Extend `PLATFORMS` map at `scripts/local-seed-raw.py:55-60` from 4 to 9 aliases (`fb_ads`, `tt_ads`, `g_ads`, `gs_earned`, `gs_atl`); remove/rewrite the "organic-only" comment at `:53-54`. |
| **FR-2** | Add `rows_fb_ads` / `rows_tt_ads` / `rows_g_ads` / `rows_gs_earned` / `rows_gs_atl` on the existing `Seeder` class, mirroring `rows_ig`/`rows_fb`/`rows_tt`/`rows_yt` at `:321-741`. `Seeder.seed_platform(alias, drop)` at `:743-772` dispatches via `getattr(self, f"rows_{alias}")` — no dispatch change. `insert()` and `_ch_type()` are frozen (NFR-8). |
| **FR-3** | Extend module-level `TYPE_OVERRIDES` at `:77-91` for spend as `Nullable(Float64)`, `gs_earned`/`gs_atl` ISO date strings, and any action-type EAV columns the paid transformers `argMax` off. Every entry keeps a one-line comment matching `:78-91` format. |
| **FR-4** | Extend `REQUIRED_COLUMNS` at `:136-166` for allow-list ↔ transform drift on the five new platforms. Regenerate by grepping `orchestration/flows/<platform>/transform_flow.py` for `argMax\(\s*[a-z_0-9]+`, diff against `load_contract()` at `:169-189`. Missing this surfaces as `NO_SUCH_COLUMN_IN_TABLE` at transform time, not at seed time. |
| **FR-5** | `--platforms` default at `:778` changes from `"ig,fb,tt,yt"` to `"ig,fb,tt,yt,fb_ads,tt_ads,g_ads,gs_earned,gs_atl"`. Validation loop at `:815-818` already refuses unknown aliases against `PLATFORMS`; FR-1 also extends validation. |
| **FR-6** | Replace `self.base = datetime(2026, 8, 1, 9, 0, 0)` at `:215` with a rolling window ending at today (use `datetime.now(timezone.utc)`, not `datetime.utcnow()` — the timezone-aware form keeps rows off the `staging_date_cutoff` edge when the seed runs near midnight UTC). Configurable window size in days, default 30. |
| **FR-7** | Add `--days` flag (default 30, cap 60) driving FR-6. Cap matches brief §4.4's `entities × days` guidance. Document in `--help`. |
| **FR-8** | Document mandatory run order in `scripts/local-seed-raw.py` module docstring **and** `scripts/local-run-pipeline.sh` header comment: `data-service/scripts/setup-local-demo.sh` → `scripts/local-seed-raw.py` → `scripts/local-run-pipeline.sh`. State that `local-seed-raw.py:238` only **reads** `frnd_os_master.account_ownership` via `Seeder.registered_account()` at `:227-243`; it does **not** write registry rows. |
| **FR-9** | Fail fast when `Seeder.registered_account()` returns `None` for a brand whose YAML declares the platform. Print `frnd_os_master.account_ownership has no rows for brand <ulid> platform <name>. Run data-service/scripts/setup-local-demo.sh first.` and exit non-zero, replacing the fallback at `:322`, `:504`, `:614`, `:686`. |
| **FR-9a** | Add `--allow-missing-account` (default off) that reverts to the fabricated-`f"<alias>-acct-{brand[:8]}"` behaviour, for the "new connector before setup-local-demo has run" case. |
| **FR-10** | `frndbank` (ULID `01ksrm715x6ptwyjjc9gtq9vys`) = single "full" brand carrying all 9 platforms / 67 raw tables. Union matches `orchestration/domain/platforms.py::PLATFORM_TO_RAW_ALIAS` and `PLATFORM_RAW_TABLES` at `:258+`. |
| **FR-11** | `frndskincare` (ULID `01ksrm715zf0ejfeje5psv0kfz`) = 6-platform subset matching `api/database/seeders/DemoWorkspaceSeeder.php`. Target 6/40; **if api tuple has drifted, api wins — do not diverge**. |
| **FR-12** | `frndairline` (ULID `01KT20EM84NMY4H2F492PVF9VK`) = 6-platform subset matching api. Target 6/45; same rule as FR-11. |
| **FR-13** | `yourfragrance` (ULID `01kxyx49wtvch7zxxe34mxkhbe`) = 5-platform subset seeded new for the raw layer. Target 5/26. Absent from `data-service/database/seeders/frnd_agg_marts/demo/_constants.py` on purpose — see data-service's PRD FR-15. |
| **FR-14** | api-integration rows added for `frndbank` only (per `q-api-integration-rows`). |
| **FR-19** | Keep in-process invocation at `scripts/local-run-pipeline.sh:53-56` unchanged. NFR-2 captures the accepted cost. Prefect-API-poll and Fivetran-webhook paths are owned by the separate `pipeline-run-visibility` feature. |
| **FR-20** | `scripts/local-run-pipeline.sh` `PLATFORMS` argument at `:24` accepts (but does not default to) `facebook_ads,tiktok_ads,google_ads,gs_earned,gs_atl`. Pass-through to `platform_pipeline_flow`, which already dispatches ads via `ADS_PLATFORMS` at `orchestration/flows/platform_pipeline_flow.py:273` and organic via the else branch. Default stays organic-only. |
| **FR-21** | Preserve the localhost guard at `scripts/local-run-pipeline.sh:41-47`. Any edit to this file leaves the guard byte-identical. |
| **FR-25** | `run-all.sh` is NOT extended to start Prefect or ClickHouse in this feature. The `q-pipeline-invocation-revisit` resolution retires brief §4.6 item 1. |
| **FR-26** | `docker-compose.dev.yml` is NOT authored in this feature. `q-clickhouse-runtime-revisit` retired the file. |
| **FR-28** | CI assertion that every alias in `orchestration/domain/platforms.py::PLATFORM_TO_RAW_ALIAS` has a matching entry in `scripts/local-seed-raw.py::PLATFORMS`. Failure message names the missing alias. Location at author's discretion — workspace-root test, or a `pytest` in `orchestration/tests/` that imports the seeder module. |

### Non-Functional (all repeated from main PRD; workspace-root owns the seeder/runner side)

- **NFR-1** — full pass under 10 min on Fahmi's MBP; seeder alone under 2 min per brand at defaults.
- **NFR-2** — in-process trigger has no production-path fidelity; local runs invisible to Prefect UI. Accepted; alternatives owned by `pipeline-run-visibility`.
- **NFR-3** — localhost guards MUST NOT be weakened. Applies to `scripts/local-seed-raw.py:789-791` (host refusal), `scripts/local-run-pipeline.sh:41-47` (Secret-block refusal), the `local` Prefect profile, and the no-`callback_url` invariant at `:54-56`.
- **NFR-5** — rolling window is size cap **and** freshness knob. Default `--days 30` (FR-6/7) keeps every fresh-seed row past `staging_date_cutoff` (`2025-01-01`); the 60-day cap keeps the seeder under NFR-1.
- **NFR-6** — fixture never carries real production data. Every seeded brand ULID is one of the four demo brands' ULIDs from the two `demo-ulids.json` files.
- **NFR-7** — declaration-driven, not hand-written. Table shape from `orchestration/config_handover/*.yaml` via `load_contract()`; column type from `_ch_type()` + `TYPE_OVERRIDES` + per-`(alias,table)` `REQUIRED_COLUMNS`. FR-28 catches a tenth connector added without a fixture.
- **NFR-8** — `insert()` (`:286`) and `_ch_type()` (`:106`) are frozen; any change requires a ledger row and is out of scope.
- **NFR-9** — the seeder MUST NOT touch `staging_<workspace_id>` or `frnd_agg_marts` row data.
- **NFR-10** — no changes to `prefect.frndos.com`; AGENTS.md hard rule 8.

## Acceptance Criteria owned here

| AC | Location |
|---|---|
| **AC-1** | `python3 scripts/local-seed-raw.py --list` prints all 9 platforms with contract table counts. |
| **AC-2** | `--brand 01ksrm715x6ptwyjjc9gtq9vys` seeds 67 tables across 9 raw DBs for `frndbank` in under 2 min at `--days 30 --posts 40`, after `data-service/scripts/setup-local-demo.sh` has run. |
| **AC-3** | Same command for the other three brands seeds subset registered in `DemoWorkspaceSeeder`. Cross-brand total: 26 raw DBs, 178 raw tables. If api tuple changes, target follows. |
| **AC-4** | Every fact-table row at default `--days 30` has timestamp in the last 30 days; no row dropped by `staging_date_cutoff`. |
| **AC-5** | Running `local-seed-raw.py` before `setup-local-demo.sh` exits non-zero on the first missing registry row with the FR-9 message, unless `--allow-missing-account`. |
| **AC-6** | `scripts/local-run-pipeline.sh frndAgency 01ksrm715x6ptwyjjc9gtq9vys` (default 4 organic platforms) completes with non-zero rows in `frnd_agg_marts.social_content_performance FINAL` per channel and `impossible` = 0 per channel (invariant already checked at `:75-86`). |
| **AC-7** | `scripts/local-run-pipeline.sh frndAgency 01ksrm715x6ptwyjjc9gtq9vys facebook_ads,tiktok_ads,google_ads,gs_earned,gs_atl` runs paid+GS chain successfully; `paid_ads_performance{,_age_gender,_region}`, `earned_content_data`, `atl_media_performance` non-zero. |
| **AC-9** | `scripts/local-run-pipeline.sh` cannot reach `prefect.frndos.com` or Cloud ClickHouse; localhost guard refuses; runner passes no `callback_url` (NFR-3). |
| **AC-10** | Adding a hypothetical tenth alias to `PLATFORM_TO_RAW_ALIAS` without a matching `PLATFORMS` entry fails FR-28. |
| **AC-14** | `scripts/local-seed-raw.py:106` (`_ch_type`) and `:286` (`insert`) byte-identical to their state at `0505be8` (NFR-8). |

## Tasks

- **TASK-1 — FR-1, FR-5, FR-28.** Extend `PLATFORMS` map, `--platforms` default, and land the CI assertion. Delete/rewrite `:53-54` comment. Anchor test path picked by author.
- **TASK-2 — FR-3, FR-4.** Extend `TYPE_OVERRIDES` and `REQUIRED_COLUMNS`. Regenerate `REQUIRED_COLUMNS` via `argMax\(\s*[a-z_0-9]+` grep of `orchestration/flows/<platform>/transform_flow.py`. Every override annotated per `:78-91` format.
- **TASK-3 — FR-2.** Add `rows_fb_ads`, `rows_tt_ads`, `rows_g_ads`, `rows_gs_earned`, `rows_gs_atl` on the `Seeder` class. Do NOT modify `insert()` (`:286`) or `_ch_type()` (`:106`) — NFR-8 + AC-14 forbid.
- **TASK-4 — FR-6, FR-7.** Rolling window with `datetime.now(timezone.utc)` at `:215`; `--days` flag default 30 cap 60; wired into `--help`.
- **TASK-5 — FR-8.** Bootstrap docstring on both `scripts/local-seed-raw.py` and `scripts/local-run-pipeline.sh` naming the mandatory order and pointing at `data-service/scripts/setup-local-demo.sh`. Reference the "reads `account_ownership` but writes nothing" invariant at `Seeder.registered_account()` `:227-243`.
- **TASK-6 — FR-9, FR-9a.** Fail-fast on missing registry rows at `:322`, `:504`, `:614`, `:686`; `--allow-missing-account` flag for the escape hatch.
- **TASK-7 — FR-10 through FR-14 execution.** Wire the four brands (with per-brand platform tuples matched to `api/database/seeders/DemoWorkspaceSeeder.php`) and the api-integration-rows-for-`frndbank`-only rule. This is a driver script or a set of `Makefile`-style shortcuts calling the seeder repeatedly; **do not** widen `DemoWorkspaceSeeder`.
- **TASK-8 — FR-20, FR-21.** `PLATFORMS` argument at `scripts/local-run-pipeline.sh:24` accepts the ads/GS aliases (default stays organic). Localhost guard at `:41-47` byte-identical.
- **TASK-9 (FR-19 verification, no code).** `scripts/local-run-pipeline.sh:53-56` in-process one-liner unchanged.

## Dependencies on other services

- **data-service (blocks all seeder tasks at AC-2/AC-3/AC-5/AC-6/AC-7).** Registry rows in `frnd_os_master.workspaces`/`brands`/`connectors`/`connector_syncs` must be present before `local-seed-raw.py --brand` will produce a matched fixture. Owned by `data-service/scripts/setup-local-demo.sh` → `data-service/database/seeders/frnd_agg_marts/demo/seed_demo.py` for the three demo brands, and `data-service/database/seeders/dummy_connector/000_seed_dummy_connector.py` for the dummy tenant. See data-service PRD FR-27, FR-29.
- **orchestration (blocks AC-7).** Without the FR-22 local-skip guard on `orchestration/flows/creative_assets/upload_flow.py`, a local `--brand frndbank` paid run with real `aws-*` Secret blocks absent will attempt an S3 client construction and fail. See orchestration PRD FR-22, FR-23.
- **api (informational).** `api/database/seeders/DemoWorkspaceSeeder.php` is the source of truth for FR-11/FR-12/FR-13 platform tuples. Do NOT edit it here to widen the matrix; conversely, if the api file drifts before implementation, the raw seeder follows. See api PRD.

## Merge order

Ship after **orchestration** (FR-22 local skip guard) and **data-service** (FR-27 setup script, FR-29 dummy_connector banner). Both are prerequisites for AC-2 through AC-7. Publishing order:

1. orchestration
2. data-service
3. workspace-root (this file's changes) — commits land on the workspace-root branch fahmi keeps
4. api — read-only; no code change

## Out of scope (explicit)

- MinIO integration; `orchestration/integrations/aws.py` untouched (FR-24).
- `docker-compose.dev.yml`; `run-all.sh` Prefect/ClickHouse wiring (FR-25, FR-26).
- Prefect-API-poll or Fivetran-webhook trigger path — owned by separate `pipeline-run-visibility` feature.
- Environment-signal authority rework at `orchestration/integrations/clickhouse.py:119` — owned by `env-cost-policy` (brief §5 Wave 2).
- `orchestration/tasks/transform_tasks.py:71-84` `raw_database`-fallback deprecation — evidence only, do not fix here (see main PRD "Known latent issue" section).

## Open Questions

None outstanding at this level. Six PRD-review open questions were closed in the main PRD `docs/prd/local-pipeline-e2e.md` Open Questions section; two were overridden (`q-onboarding-state-scope` → FR-27 and NFR-11 in data-service; `q-dummy-connector-deprecation-scope` → FR-29 in data-service). See split-time open questions in the splitter report — none blocks this file.
