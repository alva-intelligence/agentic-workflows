---
prd: local-pipeline-e2e
parent_prd: docs/prd/local-pipeline-e2e.md
service_prd: docs/prd/local-pipeline-e2e.workspace-root.md
service: workspace-root
branch: (workspace-root is NOT branched — commits land on feat/fahmi/data-agentic-setup)
base_branch: (n/a — see service PRD Bootstrap boundary)
implementation_strategy: implementation_only
pr_url: null
status: prd_split
---

# Local pipeline end-to-end — workspace-root Track

## Status

| Item | Status |
|------|--------|
| Brainstorming | completed |
| PRD | approved |
| Service PRD | completed |
| Implementation | not_started |
| PR | not_opened (workspace-root has no upstream in the usual sense) |

## Phase Progress

| Phase | phase_status |
|-------|--------------|
| brainstorming | completed |
| prd_creation | completed |
| prd_splitting | inprogress → completed at close of this split |
| implementation | idle |
| pr_submission | idle |
| pr_review | idle |
| completion | idle |

## Branch

**Workspace-root is NOT branched by this split.** It stays on
`feat/fahmi/data-agentic-setup` (three unpushed commits at start of split
carrying the `W12`/`W13` ledger rows, both briefs, and the main PRD). Do not
check out, branch, stash, reset, or commit at the workspace root outside
`feat/fahmi/data-agentic-setup`.

The main PRD at `docs/prd/local-pipeline-e2e.md` is the split source and MUST
NOT be overwritten. This service's PRD is at
`docs/prd/local-pipeline-e2e.workspace-root.md` (distinct filename to avoid
collision).

## Tasks

- [ ] **TASK-1 — FR-1, FR-5, FR-28.** Extend `scripts/local-seed-raw.py`
      `PLATFORMS` map (`:55-60`) from 4 to 9 aliases; extend `--platforms`
      default (`:778`); land the CI assertion for a tenth alias without a
      matching seeder entry.
- [ ] **TASK-2 — FR-3, FR-4.** Extend `TYPE_OVERRIDES` (`:77-91`) and
      `REQUIRED_COLUMNS` (`:136-166`). Regenerate `REQUIRED_COLUMNS` by
      grepping `orchestration/flows/<platform>/transform_flow.py` for
      `argMax\(\s*[a-z_0-9]+`. Every override annotated per `:78-91` format.
- [ ] **TASK-3 — FR-2.** Add `rows_fb_ads` / `rows_tt_ads` / `rows_g_ads` /
      `rows_gs_earned` / `rows_gs_atl` on the existing `Seeder` class,
      mirroring `rows_ig`/`rows_fb`/`rows_tt`/`rows_yt` at `:321-741`.
      `insert()` (`:286`) and `_ch_type()` (`:106`) MUST NOT be modified
      (NFR-8 + AC-14).
- [ ] **TASK-4 — FR-6, FR-7.** Replace `datetime(2026, 8, 1, 9, 0, 0)` at
      `:215` with a `datetime.now(timezone.utc)` rolling window; add `--days`
      flag default 30 cap 60; wire into `--help`.
- [ ] **TASK-5 — FR-8.** Bootstrap-order docstring on
      `scripts/local-seed-raw.py` (module docstring) and
      `scripts/local-run-pipeline.sh` (header comment).
- [ ] **TASK-6 — FR-9, FR-9a.** Fail fast at `:322`, `:504`, `:614`, `:686`
      with the FR-9 message; `--allow-missing-account` flag for the escape
      hatch.
- [ ] **TASK-7 — FR-10 through FR-14 execution.** Wire the four brands with
      per-brand platform tuples matched to
      `api/database/seeders/DemoWorkspaceSeeder.php`; api-integration-rows-for-frndbank-only
      rule.
- [ ] **TASK-8 — FR-20, FR-21.** `scripts/local-run-pipeline.sh` accepts the
      five paid/GS aliases in `PLATFORMS` (default stays organic); localhost
      guard at `:41-47` byte-identical.
- [ ] **TASK-9 (verification, no code).** `scripts/local-run-pipeline.sh:53-56`
      in-process one-liner unchanged (FR-19). No `callback_url` (NFR-3).

## Acceptance Criteria (this service)

- [ ] **AC-1** — `--list` prints all 9 platforms.
- [ ] **AC-2** — `--brand frndbank` seeds 67 tables in <2 min after
      `setup-local-demo.sh` has run.
- [ ] **AC-3** — three subset brands seed to match `DemoWorkspaceSeeder`
      tuples; totals 26 raw DBs / 178 tables.
- [ ] **AC-4** — every fact-table row within last 30 days at defaults.
- [ ] **AC-5** — pre-setup run exits non-zero with FR-9 message.
- [ ] **AC-6** — default 4 organic platforms complete with non-zero rows and
      `impossible` = 0 per channel.
- [ ] **AC-7** — paid+GS run populates
      `paid_ads_performance{,_age_gender,_region}`, `earned_content_data`,
      `atl_media_performance`.
- [ ] **AC-9** — localhost guard refuses non-local hosts; no `callback_url`.
- [ ] **AC-10** — tenth alias without `PLATFORMS` entry fails CI.
- [ ] **AC-14** — `_ch_type` and `insert()` byte-identical to `0505be8`.

## Out of scope

- MinIO; `docker-compose.dev.yml`; `run-all.sh` Prefect/ClickHouse wiring.
- Prefect-API-poll or Fivetran-webhook trigger — `pipeline-run-visibility`.
- `orchestration/tasks/transform_tasks.py:71-84` `raw_database`-fallback
  deprecation — evidence only.

## Dependencies

- **orchestration** (blocks AC-7): FR-22 skip guard.
- **data-service** (blocks AC-2/AC-3/AC-5/AC-6/AC-7): `setup-local-demo.sh` +
  `seed_demo.py` populate `frnd_os_master`; `dummy_connector/000_seed_dummy_connector.py`
  populates the dummy tenant leg.
- **api** (informational, no code): source of truth for FR-11/FR-12/FR-13
  tuples via `DemoWorkspaceSeeder`.

## Merge Order

**3 of 3.** Ship after both orchestration and data-service.

## Open Questions

See splitter report — none blocks this file.


## Amendment 2026-08-31 — FR-31 (supersedes FR-5)

| # | Task | FR | Status |
|---|---|---|---|
| TASK-A | Add `BRAND_PLATFORMS` beside `PLATFORMS` at `scripts/local-seed-raw.py:54-59`; resolve `--platforms` from it per brand when the flag is omitted; error on an unknown `--brand`. | FR-31 | not_started |
| TASK-B | Add `--brand all` to seed all four brands in one run (frndbank 9, frndskincare 6, frndairline 6, yourfragrance 5 → 26 raw DBs, 178 tables). | FR-31 | not_started |
| TASK-C | Add `--verify-matrix`: parse api's `integrationDefinitions()`, map through FR-30b's vocabulary mapping, assert equality with `BRAND_PLATFORMS`, exit non-zero naming every mismatch. | FR-31 | not_started |
| TASK-D | Add a test in `data-service/tests/` invoking `--verify-matrix` as a subprocess (workspace-root has no test infrastructure). | FR-31 / AC-3a | not_started |

### Session log — 2026-08-31

FR-5 was superseded before any code was written. Fahmi asked whether the seeder already
covers the demo brands; it does not — `--brand` is singular at `:777`, the brand × platform
matrix lived nowhere in code, and this PRD forbids a driver script. Worse, FR-5's all-nine
default was measured wrong for three of the four brands. FR-31 puts the matrix in the seeder
with a CI probe, which makes AC-3 mechanical instead of manual discipline. Ledger row `W15`.
