# Handoff — `local-pipeline-e2e`, 2026-08-30

> ## ⚠️ Arrival record — what survived the move (added 2026-08-31)
>
> This handoff reached `~/Documents/Mijn Workbench/projects/frndos` as two files in `~/Downloads`.
> **§6 was right: nothing else travelled.** Verified 2026-08-31 by `find` across the home tree —
> the only two matches for `*local-pipeline-e2e*` on this machine are the brief and this file.
>
> | §6 artifact | arrived? |
> |---|---|
> | `docs/prd/local-pipeline-e2e.md` (72 KB, 41 FR / 10 NFR / 17 AC) | **no — does not exist on this machine** |
> | `.workflow-state.json` (51 KB, 17 decisions) | **no** — this workspace's own is 27 KB and never knew this feature |
> | `docs/briefs/2026-08-30-local-pipeline-e2e.md` | yes, via Downloads; now committed here |
> | this handoff | yes, via Downloads; now committed here |
> | `docker-compose.dev.yml` | **no** |
> | `run-all.sh` | present, but this workspace's own — it carries no Prefect or ClickHouse wiring |
> | `.onboard-state.json` | present, but this workspace's own — it has **no** `prefect_setup` or `ch_local` keys |
>
> **The PRD is unrecoverable.** Its 41 FRs exist nowhere. The 17 *decisions* behind it do survive —
> §3.1–3.3 below tabulates every one — so the PRD is being **re-derived**, not reconstructed, and
> re-derived against what is actually built here rather than against the other machine's premise.
>
> **§1 steps 3–5 do not apply as written.** `.workflow-state.json` on this machine does not show
> `active_feature: local-pipeline-e2e`; it showed `insights-missing-metrics` in
> `implementation`/`inprogress`, which was itself stale — all four of that feature's PRs merged
> 2026-08-27 (api #414, web #535, data-service #217, orchestration #69) and every branch sits 0
> ahead of origin. That record was closed to `completion`/`completed` on 2026-08-31 before this
> feature was started.
>
> **§4's repository state does not describe this machine either.** No repo here is on
> `fix/fahmi/vc-deploy-topology-stale`, and the 7 unpushed commits it describes are not present.
> Re-derive base-branch currency from this machine before branching.
>
> **The brief's §3 premise is falsified here** — `scripts/local-seed-raw.py` and
> `scripts/local-run-pipeline.sh` both exist and are tracked. See the banner at the top of
> `2026-08-30-local-pipeline-e2e.md`.



Written to move this feature to another machine. Read top to bottom; §1 is what to do first,
§6 is the part that does not travel by git and needs manual attention.

**Where we are:** feature `local-pipeline-e2e`, phase **`prd_splitting` / `idle`**, type
`improvement`. Brainstorming and PRD creation are both complete and signed off. Nothing has
been implemented, no branch has been created, no code has changed.

---

## 1. First actions on the new machine

1. Read `docs/prd/local-pipeline-e2e.md` — the PRD, 1065 lines, 41 FRs. It is the spec.
2. Read `docs/briefs/2026-08-30-local-pipeline-e2e.md` — the audit it was written from, with
   `file:line` citations.
3. Confirm `.workflow-state.json` shows `active_feature: local-pipeline-e2e`, phase
   `prd_splitting`, `phase_status: idle`.
4. Bring the three base branches current **before** anything branches (see §4).
5. Run `/workflow next`-equivalent: the splitter creates
   `improvement/fahmi/vc-local-pipeline-e2e` and writes per-service PRDs.

---

## 2. The feature in one paragraph

Local developers cannot run the pipeline end to end. Onboarding Step 7.6 ("Seed the local raw
layer") probes for a seeder script that has never existed, so a local ClickHouse holds only
placeholder raw tables, every transform reads nothing, and the UI renders em dashes that look
like a pipeline bug but are an absent source. Separately there is no local Prefect server,
worker, or S3 substitute, so even with fixtures nothing would execute the flow. This feature
builds a declaration-driven raw-fixture generator covering all 9 platforms **and** the local
runtime to execute it, merged into one improvement.

Services in scope: **data-service, orchestration, api, workspace-root.**

---

## 3. Every decision, and where it came from

### 3.1 Intake (2 answers)

| decision | answer |
|---|---|
| work type | `improvement` → branch `improvement/fahmi/vc-local-pipeline-e2e` |
| scope | fixtures **+ full local runtime**, merged (originally two features) |

### 3.2 Brainstorming (8 answers, all recorded in `.workflow-state.json`)

| id | answer |
|---|---|
| `q-generator-home` | **data-service** — generalise `dummy_connector/`, read declarations via `../orchestration/` |
| `q-reference-ddl` | **capture all three** missing platforms (google_ads, tiktok, youtube) |
| `q-brand-platform-matrix` | **one full brand + subsets** |
| `q-env-signal-authority` | **`environment` Secret block** is authoritative, not `FRND_ENVIRONMENT` |
| `q-s3-substitute` | **MinIO** as default local driver; real S3 under `frnd-data/local/` as opt-in |
| `q-clickhouse-runtime` | **keep both, platform-conditional** — macOS/Linux standalone, Windows Docker |
| `q-demo-ulids-consolidation` | **consolidate now** to `.agentic-workflows/constants/demo-ulids.json` |
| `q-bootstrap-polling` | **poll the Prefect API** directly; no callback JWT wiring |

### 3.3 PRD open questions (9 answers, all ticked in the PRD's Open Questions section)

| id | answer |
|---|---|
| `q-yourfragrance-4th-brand` | **add as 4th brand with a subset** *(differed from the recommendation)* |
| `q-api-integration-rows` | add rows for the full brand only |
| `q-one-full-brand-choice` | `frndbank` |
| `q-agentic-workflows-constants-persistence` | verified — see §5, the finding changed the requirement |
| `q-staging-reference-brand-proposal` | defer to the PM / tech-lead discussion |
| `q-shared-platform-set` | matched to api's tuples |
| `q-clickhouse-credentials-choice` | `frndos_data_service` / `demo_local_pw` |
| `q-fixture-implementation-language` | stay Python in the existing seeder |
| `q-onboarding-os-detection` | explicit `FRNDOS_CH_PATH` env var |

### 3.4 The resulting fixture matrix — verified arithmetic

| brand | platforms | raw tables |
|---|---:|---:|
| frndbank (full) | 9 | 67 |
| frndskincare | 6 | 40 |
| frndairline | 6 | 45 |
| yourfragrance | 5 | 26 |
| **total** | **26 raw DBs** | **178 tables** |

Recomputed independently from `orchestration/domain/platforms.py::PLATFORM_RAW_TABLES` and
matches the PRD exactly.

---

## 4. Repository state — read before branching

**Two repos are checked out on another session's branch.** As of 2026-08-30 a separate agent
session ("Dev:Github flow") had work in flight:

| repo | HEAD | base | base behind origin |
|---|---|---|---|
| data-service | `fix/fahmi/vc-deploy-topology-stale` (3 commits) | `development` | **44** |
| orchestration | `fix/fahmi/vc-deploy-topology-stale` (4 commits) | `staging` | **21** |
| api | `develop` | `develop` | **36** |

⚠️ **Those 7 commits are unpushed and exist on one machine only.** `ls-remote` shows zero
remote matches in either repo. They are two distinct concerns sharing one branch name:
deploy-topology documentation corrections, and Windows fixes for the governance checkers.
Notably `orchestration@21bf9a2` already fixes the swapped staging/production ClickHouse host
ids found during this feature's research.

**Before the splitter runs**, bring each base current and check out the correct one — per
service, not a single `develop` assumption:

```bash
git -C data-service  checkout development && git -C data-service  pull origin development
git -C orchestration checkout staging     && git -C orchestration pull origin staging
git -C api           checkout develop     && git -C api           pull origin develop
```

That leaves `fix/fahmi/vc-deploy-topology-stale` intact in both repos — it simply stops being
what HEAD points at. **Do not branch this feature off it.**

`data-service`'s 44-commit gap matters directly: origin's `setup-local-demo.sh` fixes an
`apply_dir()` bug where `for f in $(ls …)` word-splits on paths containing a space, silently
no-opping every migration on a path like `Mijn Workbench`. This feature depends on that script.

---

## 5. Findings that change the work

**Live-cluster verification, 2026-08-30, via the ClickHouse Cloud API (read-only).**

- **STAGING** = `v6c6l832b8` "FRnD OS Brand Insight", serviceId `594e5d1d-753c-400d-ab94-e9a8bf193b07`
- **PRODUCTION** = `waopmhpq10` "FRnd OS Brand Insight Prod", serviceId `64cc32f0-3a02-49f1-a88d-8967cf6e9677`
- `e8448wgdki` "ALVA Intelligence" is **stopped** — the dead service the local `clickhouse` MCP used to target.

Raw coverage: **staging 7/9** (missing `tt` organic and `g_ads`), **production 9/9**. So the
reference-DDL capture sources youtube from staging, and tiktok + google_ads from production.

Two constraints for the capture script:
- Production raw DB names embed **real client brand ULIDs**; reference files use a generic
  `raw_<alias>_<brand_id>`. The script must genericise and must never commit a real ULID.
- **Multi-connector naming is live** in production (`raw_g_ads_2_*`, `raw_tt_5_*`). The
  generator must handle `raw_<alias>_<n>_<brand>`.

Two registry-vs-live diffs, **both benign — do not "fix" either**: `google_ads` lacks
`custom_report_lead` (OUT-027, by design), and `tiktok` carries an extra `creative_assets`
which is transformer-owned (`flows/creative_assets/ddl.py:12`) and correctly absent from
`PLATFORM_RAW_TABLES`.

**The `constants/` finding.** `.agentic-workflows/scripts/update-check.sh` only ever does
`mkdir -p` on that directory — no `rm -rf`, no `rsync`, no `cp` anywhere — so a `constants/`
subdirectory **survives an installer update**. But it would be **absent on a fresh install**,
because it is not in the upstream agentic-workflows repo, and both consumers hard-fail
(`_constants.py:44` raises `FileNotFoundError`; api's `DemoUlids` has no fallback). The PRD
therefore makes **an upstream agentic-workflows PR a hard prerequisite** of this feature.

---

## 6. ⚠️ What does NOT travel by git

**Every workflow artifact is local-only.** `Work/frndos/` is excluded by the vault's
`.gitignore` (line 38) and is not itself a repository, so none of these are tracked anywhere:

| file | size | contains |
|---|---:|---|
| `.workflow-state.json` | 51 KB | phase, all 17 decisions, the full brainstorming summary |
| `docs/prd/local-pipeline-e2e.md` | 72 KB | the PRD — 41 FRs, 10 NFRs, 17 ACs |
| `docs/briefs/2026-08-30-local-pipeline-e2e.md` | 24 KB | the audit with citations |
| `docs/briefs/2026-08-30-handoff-local-pipeline-e2e.md` | this file | |
| `docker-compose.dev.yml` | 2.7 KB | the Windows local stack |
| `run-all.sh` | 11 KB | service launcher |
| `.onboard-state.json` | 3.4 KB | onboarding completion record |

**These must be moved deliberately** — committed to a service repo on a dedicated branch and
pushed, or copied by hand. Without them the other machine has no phase, no decisions and no
PRD, and `/workflow resume` cannot reconstruct them: it reads *committed* artifacts, and there
are none.

`docker-compose.dev.yml` being untracked is also a standing problem beyond this handoff — the
PRD makes Docker the blessed Windows ClickHouse path, and that rule currently points at a file
no one else has.

---

## 7. What happens next

`prd_splitting` — the splitter creates `improvement/fahmi/vc-local-pipeline-e2e` from each
service's own base and writes per-service PRDs to `<service>/docs/prd/local-pipeline-e2e.md`.
Then `implementation`.

**Carry-in prerequisites, neither owned by this feature:**
- The upstream agentic-workflows PR shipping `constants/demo-ulids.json` (§5) — gates FR-35.
- The staging reference-brand proposal is an **open PM / tech-lead discussion**, deliberately
  not assumed by any requirement.

**Still unresolved, non-blocking:** Lark is not linked (`.lark-sync.json` absent), so this
feature does not appear on the team kanban and every `/lark-sync push` has been a no-op.
