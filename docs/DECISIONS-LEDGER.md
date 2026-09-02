# Decisions Ledger — `agentic-workflows` (framework source)

Append-only. Newest last. One row per direction change to the **framework itself** — fragments,
agent definitions, skills, templates, workflow config, manifest.

This is the framework repo's own ledger. It is **not** the workspace ledger: decisions about how a
particular workspace is wired (worktree shapes, local-only scripts, per-workspace scoping) belong in
that workspace's `docs/DECISIONS-LEDGER.md`, and service-level decisions belong in each service repo.

**Convention:** when you supersede or correct guidance, add a row here **in the same commit** as the
edit. If a whole section is retired rather than corrected, leave a banner at its head:

```
> ⛔ **SUPERSEDED** by <label> (YYYY-MM-DD). Kept for history — do not build from this.
```

---

## 2026-08-27 — `F1`: `orchestration/` becomes the fifth service, in tracked source

The frndOS workspace has had five service repos on disk since 2026-08-19, but the framework only
ever described four. The fifth was injected **after install** by
`frndos/scripts/local-wire-orchestration.sh` — a local-only, gitignored script that patches the
installed copies under `.agentic-workflows/` and `.agents/skills/`, both of which
`local-bootstrap.sh` and `update-check.sh` re-copy over. Every bootstrap erased the registration and
it had to be re-applied by hand. This row moves it into tracked source, where `update-check.sh`
distributes it like any other framework change.

| # | What changed | Supersedes | Why | Cost |
|---|---|---|---|---|
| F1 | `orchestration/` is registered as the fifth service across **34 files** of tracked source: the three core fragments; all four agent tool families (claude-code, opencode, cursor, amp); `prd` / `prd-split` conventions; `workflow` session-checks and track-conventions; `jj-workflow`; `onboard` SKILL + service-registry reference; `workflow/lark-template.json`; `workflow/gates.json`. | `frndos/scripts/local-wire-orchestration.sh` in full — every one of its 30 patches, plus the `frnd-data` copy at `UNCOMMITTED-onboard-edits.patch`. | The local script covered **claude-code only** (its own stated Known gap) and patched install copies that get overwritten. Tracked source reaches cursor, opencode and amp too, survives bootstrap, and ships through the normal `update-check.sh` path. It also closes four anchors the script never had: `skills/prd-split/SKILL.md`, `workflow/gates.json`, `claude-code/frndos-track.md`, and the base-branch map in `session-checks.md`. | The local script must keep running until this branch merges **and** each workspace has pulled the update — it is idempotent and its patches become no-ops against the new source, so leaving it in place is safe. Retire it only after `update-check.sh` has distributed this. |
| F1a | **Two claims from the local script were rejected on evidence and are NOT ported.** (a) *"`prefect.yaml` git-clones `branch: main`, so `main` deploys to staging and production at once."* The mechanism is wrong: `prefect.yaml` carries `deployments: []`, so its pull step never executes. (b) *"There is no staging branch to promote from."* A `staging` branch exists, created 2026-08-25, with PRs #63/#64/#65 merged into it. | `local-wire-orchestration.sh` §3b (onboard-registry text) and the same text in `frnd-data/UNCOMMITTED-onboard-edits.patch`. | Verified in the repo, not from memory: `prefect.yaml` on `origin/main` has `deployments: []`; `git ls-remote` lists `refs/heads/staging`; `scripts/register_paid_deployments.py` is present on both `main` and `staging` and pins branch per environment (production→`main`, staging→`staging`). | The **conclusion still holds** and is written as the corrected reason: `frnd-orchestration`'s own ledger (2026-08-26, `GOVERNANCE-DOCS`) records that `--env staging` has never been run — *"no registered deployment pulls `staging`, so `main` is still what reaches both environments"* — and `staging-pool` has no worker. So the warning survives; its stated mechanism changed from an inert YAML file to the live deployment records. If `--env staging` is ever run, **this text is the first thing that must change**, in `service-registry.core.md`, `git-conventions.md`, `onboard/SKILL.md` and `onboard/references/service-registry.md`. |
| F1b | **Mart DDL ownership is written as branch-dependent, not as a flat fact.** Orchestration owns `frnd_agg_marts` DDL via Alembic revisions applied inline by `tasks/migrate_marts.py`, **on `frnd-orchestration:staging` and `frnd-clickhouse-api:development` only** — neither repo's `main` has it, so production still runs the old split where data-service owned the DDL. | `local-wire-orchestration.sh`'s `frndos-architect` and `onboard` patches, both of which assert flatly that *"mart DDL belongs to data-service; orchestration only INSERTs"*. | That was true when the script was written (2026-08-23) and stopped being true on 2026-08-26. Flattening it either way sends someone to add a mart column in the wrong repo — the exact break `frndos/HANDOFF-2026-08-27-mart-ddl-moved.md` documents, where two `v2/*.sql` migrations landed in data-service and reached no cluster. | The framework now carries a fact with a **branch qualifier**, which is heavier to read and will go stale again when the move reaches `main`. That is the cheaper failure: a reader who checks their branch beats a reader who is confidently wrong. |
| F1c | `docs/DECISIONS-LEDGER.md` (this file) is created in the framework repo. | Nothing. `docs/` previously tracked only two SVGs. | `.claude/rules/request-integrity.md` requires a ledger row in the same commit as any direction change, and a 34-file framework change with two rejected-on-evidence corrections is exactly that. Without it the corrections live only in a commit message. | `docs/` is now part framework asset, part governance record. The distinction between this ledger and the workspace ledger in `frndos/docs/` is stated in the header above and has to be respected, or the two will drift into duplicates. |
| F1d | **A third stale claim removed: `PYTHONPATH=.` is not required.** The verify step, the start-commands table, the health-check table, `frndos-pr` and `frndos-engineer` all said the suite needs a `PYTHONPATH=.` prefix or dies with `ImportError: domain.platforms`. Corrected to `.venv/bin/pytest -q`. | F1's own text as first committed in `45791a0`, inherited from `local-wire-orchestration.sh`. | `orchestration/pyproject.toml` sets `[tool.pytest.ini_options] pythonpath = ["."]`, and its own comment says that is precisely what removes the prefix. Verified empirically with `PYTHONPATH` unset: collection succeeds under both `.venv/bin/pytest` and `python -m pytest`. Confirmed present on `origin/main`, not just a feature branch. | Third of three claims inherited from that script that turned out to be stale — after the `prefect.yaml` mechanism and the staging branch. The pattern is now established: **do not port a factual claim out of that script without re-verifying it against the repo.** Several docs inside `frnd-orchestration` still tell readers to use the prefix; those are not corrected here. |


### Known gaps

- **`orchestration/` is not added to `run-all.sh` or `references/run-all-template.sh`, and claims no
  port in the port-conflict loop.** Both are deliberate — it has no long-running process — and both
  are now stated in `onboard/references/service-registry.md` so the absence reads as a decision
  rather than an omission. The only port it can ever contend for is `:4200`, opt-in.
- **`agents/fragments/data-governance.core.md` is not included here.** That fragment (the ClickHouse
  enforcement ladder) exists on the stranded local branch `feat/fahmi/data-agentic` (`d816b14`) and
  as a plain file in `frnd-data/`, and it is a *governance* concern rather than a *registration* one.
  It needs its own row and its own commit, including the `AGENTS.md.template` wiring and a manifest
  entry.
- **`workflow/guards.json` and `scripts/verify-guards.py` are likewise not included** — same branch,
  same reason, same shape of follow-up.
- **No new files are registered in `manifest.json`.** Every file this row touches was already
  distributable, so the CI hash job covers them. Adding the governance fragment above **will** need a
  manifest entry with `sha256: "PLACEHOLDER"`.
- **Only `claude-code` has `frndos-architect` and `frndos-engineer` definitions.** The Agent-Teams
  pair does not exist for cursor, opencode or amp, so those two files' orchestration guidance reaches
  Claude Code users only. Pre-existing, not introduced here.
- **`opencode/frndos-prd.md` and `cursor/frndos-prd.mdc` have no "check recent commits on base
  branches" step**, so they received the `services:` enum but not the base-branch map. Pre-existing
  divergence between the tool families.

---

## 2026-08-27 — `F2`: the orchestration *setup* layer — guards, MCPs, and the blocks gate

`F1` taught the framework that orchestration exists. It did not teach `/onboard` how to **set a
machine up** for it. A developer who picked Orchestration got a clone, a venv and a test command,
and then: no Prefect profile, no Secret blocks, no MCP, and — the sharp end — **no guard rails on an
estate that serves production**. These rows close the first three of ten gaps found by walking the
onboarding surface step by step.

| # | What changed | Supersedes | Why | Cost |
|---|---|---|---|---|
| F2 | `skills/onboard/references/claude-settings.json` gains **19 deny** and **15 allow** entries, plus a `$comment_prefect` explaining each class. Denied: the three `prefect-frnd` MCP tools that create or cancel flow runs; `prefect profile use` / `config set`; `deployment run` / `deploy` / `block create` / `block delete` / the two `set-concurrency-limit` commands; `*register_paid_deployments*` and `*simulate_load*`; `clickhouse client` / `clickhouse-client`; and Edit/Write on `orchestration/prefect.yaml` + `orchestration/deployments/**`. Allowed: 13 read-only `prefect` queries, plus blanket `mcp__prefect-frnd__*` and `mcp__clickhouse-remote__*`. | Nothing in this repo — these rules previously existed **only** in `frndos/.claude/settings.json`, which is gitignored, and in `orchestration/.claude/settings.json`, which is tracked in that repo and therefore absent from a workspace that has not cloned it. | A fresh workspace had no protection at all: `prefect deploy` and `prefect deployment run` against `frndos_prefect` were one tool call away, and that server is staging **and** production. `profile use` / `config set` are worse than they look — they rewrite `~/.prefect/profiles.toml` globally and silently retarget the user's own terminal, not just the agent's. | Ported verbatim from Fahmi's live workspace file rather than authored fresh, so the framework and his machine agree. **The blanket `mcp__prefect-frnd__*` allow relies on deny taking precedence over allow**; if that ever stops holding, three write tools become reachable. Stated in the `$comment_prefect`. Only `prefect-frnd` is covered — `prefect-alva` is a different estate belonging to a different job and is deliberately out of scope; the comment says to mirror the rows for any second estate. |
| F2a | `references/mcp-configs.md` gains **Prefect MCP** (`uvx prefect-mcp-server`, `PREFECT_PROFILE=frndos_prefect` pinned in `env`) and **ClickHouse MCP** (remote HTTP, `https://mcp.clickhouse.cloud/mcp`, browser OAuth), each with all four tool-family templates. Step 11 lists both under Optional MCPs. | Nothing — the file previously covered Context7, Agentation, GitHub, Laravel Boost, Sentry, Lark (CLI) and Figma, and named no data-platform server. | Scoped the way Laravel Boost is: Prefect for Orchestration only, ClickHouse for Orchestration **or** Data Service. The `PREFECT_PROFILE` env pin is documented as the safety mechanism, not a convenience — it fixes the server to one estate for its lifetime so a stray `profile use` elsewhere cannot retarget it. | The Prefect MCP **hard-depends on Step 6b** having run; without `~/.prefect/profiles.toml` the server starts and every call fails with a connection error. Step 11 now says to configure it after 6b. Commands use bare `uvx`, not the absolute path in Fahmi's own config, so the template is portable — a machine without `uvx` on PATH will fail differently than his did. |
| F2b | New **Step 6b — Prefect profiles & Secret blocks**, a STOP gate placed between Step 6 (`.env` files) and Step 7 (local databases), h2 to match the `Step 2.5` / `Step 9.5` convention. Covers the two-artifact split (profiles file outside the repo, Secret blocks on the server), the ask-and-wait flow, read-only verification, and `steps.prefect_setup`. | Nothing. Step 6 handled `.env` files only, and orchestration has none. | Orchestration is the only service whose credentials live in two places, neither of them a `.env`: `~/.prefect/profiles.toml` (**outside the workspace**, plaintext, from the Lark `secrets` folder) and Secret blocks on the Prefect server. Without a step, a developer reached Step 7 with no connection and no idea one was needed. | **The agent is explicitly forbidden from writing `~/.prefect/profiles.toml`** — it carries a plaintext production credential and lives outside the workspace, so the user copies it themselves. Verification uses `PREFECT_PROFILE=<p> prefect ...` prefixes only; the step states that `profile use` / `config set` are the wrong tool and are denied. The real Secret blocks are created in Step 7.4, which is **not built yet** (gap 4), so 6b currently ends by pointing forward at a step that does not exist. |
| F2c | **`env_status: "n/a"` is declared to satisfy the `env_files` gate**, and `steps.prefect_setup` is declared advisory and non-blocking. Both added to the `.onboard-state.json` schema block. | The gate as written: *"`env_files` is not `completed` for ALL selected services"*. | This is a blocker `F1` would have introduced and did not catch. Orchestration has no `.env`, so `F1` set its `env_status` to `"n/a"`. A strict equality check against `"completed"` would therefore **block `/workflow start` forever** for anyone who selected Orchestration — and the state file would look perfectly correct while doing it. Found by reading the gate, not by hitting it. | The exemption is stated in prose in `onboard/SKILL.md`, **not enforced in code** — `workflow/gates.json` and the `/workflow` skill were not changed. If the gate is ever implemented as a literal string comparison, this row is the thing that has to be honoured. |

### Known gaps — the remaining seven of ten

> ⛔ **SUPERSEDED** by `F3` (2026-08-27). All seven are closed there except the repo-side half of
> gap 10. Kept for history — do not build from this list.

Found in the same walk; none is started.

- **4. No Step 7.4 for local ClickHouse + local Prefect.** The recipe exists and is verified in
  `orchestration/docs/setup/quickstart.md` §2: `prefect server start` → `profile create local` →
  Secret blocks → `work-pool create local-pool --type process` → `worker start --pool local-pool` →
  `variable set staging_date_cutoff` → smoke via `testing-worker/smoke-testing`. Two terminals, so it
  needs the `references/external-steps.md` protocol. **Step 6b points forward at this.**
- **5. `flake.nix` has no ClickHouse client and no orchestration line in its `shellHook`.** Prefect
  needs no system package — it arrives via `requirements.txt`.
- **6. Step 2B (Homebrew) has no ClickHouse client row.** Client only; no server.
- **7. `steps.ch_local` is not defined** — only `prefect_setup` was added.
- **8. Step 10 installs no data-engineering skills.** A data engineer gets `git-commit` and `prd` and
  nothing else, while `web/` gets five.
- **9. `launch.json` / `launch-direct.json` have no opt-in `prefect-server` entry on `:4200`.**
- **10. `local-seed-raw.py` still lives in `frndos/scripts/`, gitignored.** Until it moves into
  `frnd-orchestration/scripts/`, a local cluster has 5-column placeholder `raw_ig_*` tables, every
  transform reads nothing, and every metric renders as an em dash — which reads as a pipeline bug and
  is not one.

### Pre-existing framework bugs found during the walk — none fixed here

> Two of the four (the `flake.nix` health URLs and the duplicate `## Step 7`) are **fixed in `F3`**
> (2026-08-27). The Lark contradiction and the `run-all-template.sh` guards remain open.

- **`flake.nix` health-checks two wrong URLs.** It curls `localhost:9191/health` and
  `localhost:9999/health`; the registry says API is `/api` (any response = up) and data-service is
  `/api/v1/health/` (**401 = up**). The flake reports both services down when both are fine.
- **Two sections are both `## Step 7`** in `onboard/SKILL.md` — "Initialize Local Databases &
  Services" and "Create run-all.sh". Any reference to "Step 7" is ambiguous.
- **Lark is documented twice, contradictorily.** Step 1.6 offers "Lark MCP" and Step 11 walks through
  collecting an App ID/Secret and *writing* a Lark MCP config; `references/mcp-configs.md` states Lark
  no longer uses an MCP and gives removal instructions for all four tools. `claude-settings.json`
  still allowlists `mcp__lark__*`.
- **`references/run-all-template.sh:156-159` env guards are mis-grouped.** `[[ ! -d X ]] || [[ -f
  X/.env ]] && log_ok … || log_warn …` mixes `||` and `&&` without grouping, so the "directory exists"
  branch can report ok for a missing `.env`.

---

## 2026-08-27 — `F3`: the rest of the orchestration setup layer

Closes gaps 4–9 from `F2` and the framework half of gap 10. Written against the repo as it is, not
transcribed from `orchestration/docs/setup/` — that guide is partly stale and three of its
instructions are wrong today (see `F3d`).

| # | What changed | Supersedes | Why | Cost |
|---|---|---|---|---|
| F3 | **New Step 7.4 — Local ClickHouse & Prefect** (gap 4), placed inside Step 7 after 7.3. Seven sub-steps: CH client check, confirm the `local` profile, Terminal 1 server, Secret blocks via UI, the `staging_date_cutoff` Variable, work-pool + deployments + worker, smoke test. Records `steps.ch_local`. | `F2b`'s cost cell, which said 6b "ends by pointing forward at a step that does not exist". It exists now. | Orchestration's equivalent of 7.1–7.3. Without it a developer finished onboarding with a cloned transform layer and no way to execute a single flow. | Two long-running processes, so it needs `references/external-steps.md` and cannot be fully agent-driven. Three of its seven sub-steps are **user-run by construction** — see `F3a`. |
| F3a | **Step 7.4 routes around its own guards deliberately, and says so at each point.** `prefect profile use` / `config set` (7.4.2), `prefect block create` (7.4.4) and `*register_paid_deployments*` (7.4.6) are all denied by `F2`, and all three are genuinely needed to stand up a local estate. Each is handed to the **user** with the reason stated inline. | Nothing. | The alternative was weakening the deny rules, which would have re-opened the production path to buy local convenience. A denied command the user runs knowingly is strictly safer than an allowed one the agent runs by habit. `register_paid_deployments.py` is the sharp one: it takes `--env`, but the **active profile** decides which server it writes to, so the identical command registers locally or against `prefect.frndos.com` depending on a prefix. | Onboarding is no longer fully hands-off when Orchestration is selected. Accepted. Also: `--env production` is the correct flag for a *local* run — it produces the unsuffixed names the local worker expects — and that reads alarmingly, so 7.4.6 calls it out explicitly to stop anyone "fixing" it to `--env staging`. |
| F3b | **New Step 7.5 — seed the local raw layer** (framework half of gap 10). Probes **both** `orchestration/scripts/seed_local_raw.py` and `scripts/local-seed-raw.py`, and degrades to a plain message if neither exists. | Nothing. | A local cluster's `raw_ig_*` tables are 5-column placeholders, so transforms read nothing and every downstream metric renders as an em dash — which reads as a pipeline bug and is not one. Naming that in onboarding stops the false bug report. | **The repo half of gap 10 is not done** — the seeder still lives in `frndos/scripts/`, gitignored, and moving it means a branch and PR in `frnd-orchestration`, a different repo currently carrying in-flight feature work. The dual-path probe is what makes the step correct meanwhile, not a substitute for the move. |
| F3c | **`flake.nix`**: ClickHouse reported in the `shellHook` **but deliberately NOT added to `buildInputs`** (gap 5); an opt-in `:4200` Prefect line; both broken health-check URLs fixed. **Step 2B** gains a ClickHouse row using the Homebrew **cask** (gap 6). | The `flake.nix` health block, which curled `localhost:9191/health` and `localhost:9999/health`. | Neither URL exists: the API's check is `/api` with *any* response meaning up, and data-service's is `/api/v1/health/` where **401 means up**. The flake reported two healthy services as down. On the package: nixpkgs' `clickhouse` is the full **server** and its darwin build is unreliable, and this flake targets darwin only — adding it to `buildInputs` risks breaking `nix develop` for everyone to save one out-of-band install. Verified on the brew side: `brew install clickhouse` fails with `No available formula`, `clickhouse-cpp` is a C++ client library, and the working route is the cask (`brew install --cask clickhouse`, 26.7.5.10) or the official one-line installer from clickhouse.com. | Nix users get a *reported* dependency they must install themselves — an inconsistency with every other tool in the flake, taken knowingly. **Nix is not installed on the machine this was authored on, so the `shellHook` edits are unverified by execution**; they were checked for the one hazard that matters, `${` interpolation inside a Nix `''` string, and there are zero occurrences. |
| F3d | **Three instructions in `orchestration/docs/setup/` are contradicted and not followed.** (a) `quickstart.md` says `prefect profile use local` — denied; Step 7.4 uses `PREFECT_PROFILE=` prefixes throughout. (b) Both guides say to run `scripts/setup_prefect_blocks.py` from `prefect_blocks.example.yaml` — **neither has ever existed**; the only block script is `setup_staging_blocks.py`, which targets remote `-staging` siblings, not local. (c) Both use `venv/`; the framework creates `.venv/`. | `orchestration/docs/setup/quickstart.md` §2 and `01-prefect-and-blocks.md` §3, as sources to transcribe. | Fourth, fifth and sixth stale claims found in this work, after the `prefect.yaml` mechanism, the staging branch and `PYTHONPATH=.`. The pattern holds: **verify before porting.** Point (b) was already recorded in that repo's own ledger under `PER-ENV-P1.5` and the docs were never corrected. | The framework and that repo's setup guide now disagree in three places, and **the guide is the one that is wrong**. Not fixed here — different repo. A developer reading both will hit the contradiction; `references/service-registry.md` already warns about (b). |
| F3e | **`steps.ch_local`** added to the state schema, advisory and non-blocking (gap 7). **Step 10** gains an Orchestration block that installs **nothing** and instead names the five skills that repo already ships (gap 8). **`launch.json` + `launch-direct.json`** gain an opt-in `prefect-server` config on `:4200` with a `$comment_prefect_server` (gap 9). **The duplicate `## Step 7`** is renamed `Step 7b: Create run-all.sh`. | The second `## Step 7` heading. | Step 10 installs no community data skills on purpose — `orchestration/.agents/skills/` ships `pipeline-change`, `platform-flow`, `mart-loader`, `metric-lineage` and `prefect-audit-load`, symlinked into `.claude/skills/` and loaded on clone. Installing community duplicates over them is the failure to avoid; the step names them instead, and offers `npx skills find` rather than invented package names. The rename was forced: inserting 7.4/7.5 put the two identically-numbered headings adjacent. | Grepped first — nothing referenced onboard's "Step 7: Create run-all.sh", so the rename breaks no link. `Step 8`–`Step 12` keep their numbers; the doc now has `6b` and `7b`, which is a convention, not an accident. The `prefect-server` launch entry must be **removed** from a workspace that did not select Orchestration, or the editor offers a config that cannot start. |

### Known gaps after F3

- **The repo half of gap 10** — move `local-seed-raw.py` → `frnd-orchestration/scripts/seed_local_raw.py`.
  Needs a branch and PR in that repo; `frndos/orchestration` is currently on
  `feature/fahmi/vc-insights-missing-metrics`, so this must not be done by switching that tree.
- **Two `F2` framework bugs remain open**: the Lark MCP contradiction (Step 1.6 and Step 11 configure
  an MCP that `references/mcp-configs.md` says to remove; `claude-settings.json` still allowlists
  `mcp__lark__*`), and the mis-grouped `||`/`&&` env guards at `references/run-all-template.sh:156-159`.
- **`workflow/gates.json` still does not encode the `env_status: "n/a"` exemption** — `F2c` states it
  in prose only.
- **Nothing in `F3` is verified by running it.** No Nix on the authoring machine, no local Prefect
  server started, no Secret blocks created. The commands come from that repo's guide corrected
  against its code; the first real run of Step 7.4 should be treated as the test.

---

## 2026-08-27 — `F4`: self-review of `F1`–`F3` before PR

Fahmi asked for a review pass before the branch goes to the tech lead. Six defects in the branch's
own work, found by reading the diff as a critic rather than as the author. All six are fixed here.
None was found by a test — this branch has no executable surface, which is itself the point of `F4f`.

| # | What changed | Supersedes | Why | Cost |
|---|---|---|---|---|
| F4a | **The permission patterns did not match the commands the skill prescribes.** All 13 read-only Prefect allows and all 8 mutator denies were written only against bare `prefect ...`. Every prefect rule is now listed **twice**, bare and `.venv/bin/prefect ...`. Allow 72→87, deny 24→32. | `F2`'s allow/deny lists as committed in `b478b67`. | The sharpest defect on the branch, and it cut both ways. `prefect` is installed into `orchestration/.venv` by `requirements.txt` and is **not on PATH** on a fresh machine, so `F3` correctly wrote every command as `.venv/bin/prefect`. A `Bash(prefect deployment run:*)` deny does not match `.venv/bin/prefect deployment run` — so the guards `F2` was written to install were **bypassable by the exact invocation `F3` prescribes**, and every read-only query would have prompted. | The lists are twice as long and every future prefect rule must be added in both forms. Stated in `$comment_prefect`. A third invocation form (an activated venv, `source .venv/bin/activate && prefect ...`) matches the bare pattern, so it is covered. |
| F4b | **`git-conventions.md`'s strongest rule did not cover `main`.** "NEVER work directly on develop/development" now reads "NEVER work directly on a base branch — `develop`, `development`, **or `main`**", with the reason. | That line as written since before this branch. | `F1` made `main` a base branch for orchestration and left the prohibition enumerating the other two. A literal reader would conclude committing directly to `main` is permitted — on the one branch that reaches staging and production. | None. The rule got broader, not narrower. |
| F4c | **Bare `prefect` corrected to `.venv/bin/prefect`** in Step 6b.2 (two commands), Step 7.4.2, the 7.4.5 sync note, and the `service-registry.md` opt-in start row. Step 6b.2 gains a note explaining that prefect lives in the venv. | `F2b` and `F3`'s own text, which mixed both forms. | Step 6b runs **after** Step 5.2 installs into `.venv`, but **before** anything activates it. Every bare-`prefect` verification command in 6b would have failed with command-not-found on a clean machine — the first Prefect command a new developer ever runs. | None. |
| F4d | **A nine-line prose paragraph was removed from `frndos-architect.md`'s `## YOUR SCOPE (STRICT)` list** and rebuilt as its own `### The api → orchestration → data-service chain` section with three numbered watch-points. | `F1`'s edit to that file. | The paragraph was inserted as bullet #2 of a six-bullet CAN/MUST-NOT permission list, burying four permission rules — including three MUST NOTs — under prose that is not a permission at all. A STRICT scope list has to stay scannable. | The mart-DDL branch qualifier now lives further from the "you CAN read all service directories" line it qualifies. Judged the better trade. |
| F4e | **A blockquote that split a bullet list in two** is moved below it in `frndos-engineer.md`. | `F1`'s edit to that file. | The warning was inserted between `- **Target branch:**` and `- **Feature slug:**`, which terminates the Markdown list and restarts it — so the last two fields of the spawn-prompt checklist rendered as a separate orphaned list. | None. |
| F4f | **`service-registry.md`'s absolute ban on `prefect profile use` / `config set` now names its one exception** — creating a missing `local` profile in Step 7.4.2, user-run. | The bullet as written in `F2`. | The registry stated an absolute; `F3` then handed both commands to the user. Two documents in the same skill disagreeing is exactly the failure the ledger protocol exists to stop, and it was introduced by this branch, one commit apart. | The rule is no longer a flat absolute, so it is marginally easier to rationalise an exception. The exception is named and scoped to one step and one actor. |
| F4g | **A footnote inserted inside the Step 2B tool table orphaned its last two rows.** The ClickHouse row is moved to the end of the table and its footnote below the table; the footnote's `curl … \| sh` is reworded so no stray pipe sits near table markup. | `F3c`'s Step 2B edit. | The blank line plus six-line footnote ended the table, so `| git |` and `| gh |` rendered as literal pipe text rather than rows — in the install matrix a developer follows on a fresh machine. Same class as `F4e`, missed by the first review pass because that pass read the rendered intent rather than the raw structure. | Found only when the diff was read hunk-by-hunk on request. A mechanical check now exists and was run over all 40 touched files: **42 tables, every one carrying its own header separator.** That check is ad-hoc, not committed — a `check_governance_docs.py`-style rule would be the durable fix. |

| F4h | **Both launch configs are restored to their original compact formatting.** `json.dumps(indent=2)` had re-wrapped every `runtimeArgs` array one-element-per-line, so a 13-line addition arrived as a 103-line diff. The new configuration is now appended to the original text rather than re-serialised. | The two files as committed in `30ff4ca`. | Nothing functional — the JSON parsed either way. But a reviewer opening `launch.json` saw 61 changed lines of which 13 were real, which is exactly how a genuine change gets waved through. Reformatting an unrelated file is a review cost paid by someone else. | The append is textual, so a future edit to these files must not go through `json.dumps` either. Both are re-validated with `json.loads` before writing. Diff for the pair: **103 changed lines → 19.** |


### What the review did not find

Checked and clean: `session-protocol.core.md`, `session-checks.md`, all four tool families'
enum/base-branch edits, both `launch*.json`, `mcp-configs.md`, `workflow/gates.json`,
`workflow/lark-template.json`, and the `env_status: "n/a"` exemption text. `AGENTS.md` regenerated
after `F4b` (387 lines) — `git-conventions.md` is a fragment, so the generated file drifts if it is
not re-run.

### Standing caveat, restated because it is easy to lose

**Nothing on this branch is verified by execution.** It is documentation, permission patterns and
one Nix `shellHook`. There is no Nix on the authoring machine, no local Prefect server was started,
no Secret block was created, and no `/onboard` run was performed end to end. `F4a` is proof that
defects here are found by reading, not by running — so the first real `/onboard` with Orchestration
selected should be treated as the test, and Step 7.4 as the part most likely to need correction.

---

## 2026-08-27 — `F5`: the end-to-end run, and orchestration becomes staging-first

Fahmi asked for the branch to be *run*, not read: bootstrap a fresh workspace from the working tree,
onboard orchestration into it, and loop. Six iterations. **Six defects that neither review pass could
have found**, plus one discovery that changed the branch policy. Nothing in `F1`–`F4` was verified by
execution; this section is what execution found.

| # | What changed | Supersedes | Why | Cost |
|---|---|---|---|---|
| F5a | **`scripts/update-check.sh:389` fresh-workspace detection now counts `orchestration`.** | The loop as written since before this branch. | Found only in the **installed** tree — every source sweep in `F1`–`F4` searched `agents/`, `skills/`, `workflow/` and `templates/` and never `scripts/`. A workspace with only `orchestration/` cloned was reported as "fresh, no services" and re-offered onboarding. | The sweep habit was wrong, not just the file. Any future service registration must include `scripts/`. |
| F5b | **Step 5.1 resolves a 3.12 interpreter explicitly** (`command -v python3.12 \|\| command -v python3`) and verifies it, with a ⚠️ to stop and ask when it is not 3.12. | `F1`'s `cd orchestration && python3 -m venv .venv`. | Measured: the venv built on **Python 3.14.6**. brew's `python@3.12` is keg-only and does not relink `python3`, so the pinned version in Step 2B does not reach Step 5.1. The deployed worker runs 3.12 and `pyproject.toml` pins `target-version = "py312"` explicitly against "the interpreter that happens to be on a contributor's PATH". | **It still works** — 236 tests pass on 3.14 — so this is a silent divergence, not a failure. Verified on this machine that `python3.12` is absent and the fallback plus warning fire correctly. |
| F5c | **The Step 12 health check is now `pytest --collect-only`, not a green suite**, and the suite result is reported separately. | `F1`'s verify block. | `main` and `staging` both carry one pre-existing failure (`test_fb_pages_swap.py::test_substitution_order_when_reel_branch_real_with_inner_empty`) — already recorded in the workspace ledger at `W3`. So the block printed *"✗ Orchestration — suite failed; check .venv and requirements-dev.txt"* on a **correct** install, pointing every new developer at the wrong cause. Collection proves the venv, the deps and the import path, which is all onboarding is responsible for. | The check no longer notices a genuinely broken test suite. Deliberate: that is the PR agent's job, not onboarding's. Baselines are stated per branch — `staging` 1/236, `main` 1/206. |
| F5d | **`-q` dropped from every pytest invocation.** | `F1d`, which introduced `.venv/bin/pytest -q`. | `pyproject.toml` already sets `addopts = "-q"`. Passing it again yields `-qq`, which **suppresses the `N failed, N passed` summary line** — so the run printed the failing test name and no counts, which reads far worse than the truth. | None. Documented in the registry so nobody re-adds it. |
| F5e | **`frndos-splitter` gains the `orchestration` service→path row.** | `F1`'s edit to that file, which added the base-branch line and missed the path table. | Without it `/prd-split` has no mapping for `orchestration/docs/prd/<slug>.md` or `orchestration/docs/tracks/<slug>.track.md`. Found by running `local-wire-orchestration.sh --check` against the freshly bootstrapped workspace, which reported `missing 1`. | That script remains a useful audit even after it stops being a patcher — its other four "would apply" rows are marker mismatches, not gaps. |
| F5f | **`orchestration` is now staging-first across 23 files: base branch and PR target move `main` → `staging`, the clone checks out `staging`, and a new "Promoting orchestration to production" section defines the `staging` → `main` promotion PR.** | Every "target `main`" instruction on this branch — `F1`, `F2` and `F3` alike — and `F1a`'s conclusion that "`main` is still what reaches both environments". | **`--env staging` has been run.** Read-only probe of `prefect.frndos.com`, 2026-08-27: `platform-pipeline/webhook-sync-staging` carries `'branch': 'staging'`, pool `staging-pool`, queue `ads-staging`, tag `branch:staging`; the production twin carries `'branch': 'main'`, pool `local-pool`, queue `ads`. Both pools report `status=READY`, meaning a live worker polls each. `origin/main` is a **strict ancestor** of `origin/staging` (43 behind, 0 ahead) — the repo has already been working this way, PRs #66 and #67 included. Fahmi's decision, put to him with the evidence. | **This is the fourth time a claim sourced from that repo's own documents turned out stale**, after the `prefect.yaml` mechanism, the staging branch, and `PYTHONPATH`. `orchestration/AGENTS.md` hard rule 1 still says *"`main` deploys to staging AND production at once"* — now false, a different repo, **not corrected here**, and explicitly flagged in the framework text as stale. The promotion step is **manual by design**: `post-merge.yml`'s `promote` job is dropped in that repo, so nothing automates it. |

### What the run confirmed working

Bootstrap installs **77/77 files, 0 missing**, into a fresh workspace built from the working tree.
`AGENTS.md` generates (423 lines). Orchestration reaches **38 installed files**. **64 runnable bash
blocks** across 9 targets parse under `bash -n` (12 placeholder templates correctly skipped). The
real path runs end to end: clone → venv → `requirements.txt` + `requirements-dev.txt` → docs scaffold
→ verify. ClickHouse client detected (26.8.1.71). Step 7.5's seeder probe degrades correctly when
neither path exists. Step 6b.2's read-only estate check works against the live server — it is what
found `F5f`.

### Known gaps after F5

- **Still not executed:** Step 7.4's local Prefect server, Secret blocks, work pool and worker. They
  need two terminals and real credentials. Steps 7.4.1 (ClickHouse client) and 6b.2 (read-only estate
  verification) *were* run; the rest of 7.4 was not.
- **No `/onboard` run driven by the skill itself.** Every block was executed by hand, verbatim from
  the file. The questionnaire, the STOP gates and the state-file writes are unexercised.
- **`python3.12` is absent on the authoring machine**, so the happy path of `F5b` — resolving a real
  3.12 — was never observed, only its fallback.
- **The promotion PR has never been opened.** The section describing it is written from the branch
  topology, not from having done it once.
- Everything from `F3`'s and `F4`'s gap lists that was not touched here remains open.

---

## 2026-08-27 — `F6`: local ClickHouse becomes a real step, shared by two services

`F1`–`F5` gave orchestration a Prefect story and no database story. Comparing it against what the
framework does for Postgres exposed the actual hole: **`data-service` is a first-class service on
`:9999` and onboarding has never set up a database for it, never run a migration, never seeded a
row.** Before this branch `onboard/SKILL.md` mentioned ClickHouse zero times in any setup capacity.

Three seeding philosophies were found, and the framework encoded exactly one:

| Service | Schema | Data | In the framework before this row |
|---|---|---|---|
| api / Postgres | `artisan migrate`, 541 files, run by onboard | **restore reality** — a sanitized prod dump from arhen; the 29 Laravel seeders are never invoked | ✅ fully, with a blocking gate |
| data-service / ClickHouse | 93 `.sql`, globally numbered, **no runner** | **manufacture realism** — generate, then copy-and-rewrite for demo brands | ❌ nothing |
| orchestration / ClickHouse | 20 Alembic revisions applied **inline by the flow** | **derive from the contract** — shapes from the Fivetran allow-list | ⚠️ only `F3`'s raw-seed probe |

| # | What changed | Supersedes | Why | Cost |
|---|---|---|---|---|
| F6a | **Step 7 restructured**: `7.4 Local ClickHouse` (shared, data-service and/or orchestration) · `7.5 Local Prefect` (orchestration only, the old 7.4.2–7.4.7 renumbered) · `7.6 Seed the local raw layer` (the old 7.5). 7.4 has five sub-steps: install, start the server, users + grants + migration tracker, apply the 93 migrations, seed. | `F3`'s single `7.4 Local ClickHouse & Prefect — Orchestration only`. | ClickHouse is a database and belongs beside 7.1's PostgreSQL; Prefect is an orchestrator and is a different thing. Grouping them under one heading also made the ClickHouse half look orchestration-only, which is exactly the mistake that left data-service with nothing. The two services **share one local cluster** — orchestration writes `frnd_agg_marts.*`, data-service reads them out. | Forward references had to move with it: Step 6b's blocks pointer, both `launch*.json` comments, `steps.ch_local`'s description. |
| F6b | **`F3`'s claim that ClickHouse needs no local server is withdrawn.** 7.4.1 is now a two-mode table — remote cluster vs local server — stating that the choice decides whether 7.6 is available at all. | `F3c` / `F3`'s 7.4.1: *"The **client** is all that is needed — no local server … never at a local server this step creates."* | False three ways. The `clickhouse` binary **is** both client and server — which is why `brew install clickhouse` finds no formula. `data-service/README.md` §4 documents installing a local server. And `local-seed-raw.py` **refuses any host but `localhost`** (line 789, port 8123), so in remote mode `F3b`'s whole step is dead. | The framework now documents a second optional local service. Ports `8123`/`9000` added to the port-conflict note beside Prefect's `4200`. |
| F6c | **Two errors in `data-service/database/README.md` are corrected in place rather than copied.** Its `schema_migrations` DDL uses `ENGINE = SharedMergeTree(...)`, and it creates the table without creating `frnd_meta` first. | that file, as a source to transcribe. | `SharedMergeTree` is **ClickHouse Cloud only** — verified, not assumed: `clickhouse local` on 26.8.1.71 returns `Code: 56 … Unknown table engine SharedMergeTree`. The step uses `MergeTree` locally and adds the missing `CREATE DATABASE`. Checked separately that this does **not** affect the migrations themselves: across the 93 files the engines are `ReplacingMergeTree` 65, `MergeTree` 14, `SummingMergeTree` 1, `SharedMergeTree` **0** — they all run on an OSS server. | Fifth stale claim sourced from a service repo's own docs. That repo is not corrected here. |
| F6d | **7.4.2–7.4.5 are marked `user runs these`**, with the reason inline, and the agent is given the read-only work it *can* do: `curl -s http://localhost:8123/ping`, counting the 93 files, reading any file a failure names. | 7.4 as first written in this same session, where all nine `clickhouse client` invocations were agent-run bash blocks. | **Found by the guard blocking me.** `Bash(clickhouse client:*)` and `Bash(clickhouse-client:*)` are denied — added in `F2`, ported from Fahmi's live workspace file — so the step I had just written could not be executed by an agent at all. The deny is right: `clickhouse client --query "…"` carries arbitrary SQL as its payload, so the pattern cannot separate a `SELECT` from a `DROP`, and these sub-steps create users, grant privileges, apply 93 DDL files and insert seed rows. Same shape as 7.5.3 and 7.5.5. | Onboarding is now hands-off for neither ClickHouse nor Prefect when those services are selected. Accepted, for the same reason as `F3a`: a denied command the user runs knowingly beats an allowed one an agent runs by habit. The `curl` alternative was verified against a live local server — it returns `Ok.` |
| F6e | **The `demo-ulids.json` split is documented at the point of use**, in 7.4.5. | nothing — it was previously recorded only as an observation. | `seed_demo.py` reads `data-service/demo-ulids.json`; the api's `DemoWorkspaceSeeder` reads `api/demo-ulids.json`. **Two copies, no shared source.** The `demo-mode-db-seeded` PRD specified `.agentic-workflows/constants/demo-ulids.json`, read via `base_path('../.agentic-workflows/constants/demo-ulids.json')` — that path has never existed. If Postgres and ClickHouse demo data ever disagree, this is the reason, and 7.4.5 now says so where someone seeding will read it. | Documenting a duplication is not fixing it. The single-source file is still not created. |
| F6f | **7.4.4 gains a "same DDL lives in two repos" section**, and the "Alembic contradiction" I reported to Fahmi is **withdrawn — there is no contradiction.** | my own claim, one message earlier, that `data-service/database/README.md`'s "do not use Alembic" and orchestration's use of Alembic were unreconciled positions on the same tables. | Read the revisions instead of inferring from their existence. `m001` is four lines: `run_sql_file('frnd_agg_marts/v2/001_create_paid_ads_performance.sql')`, with a docstring saying *"That file stays the source of truth; this revision only records that it ran, and in what order."* Alembic here is an **ordering and tracking wrapper**, not a DDL generator — and the README's objection (transactional rollback) does not apply because `downgrade = irreversible(...)`. Measured: **55 `.sql` files in each repo, all 55 byte-identical, zero drift**; Alembic wraps 18 of the 36 tables and data-service's tree carries 18 more it never wraps; every file is `CREATE TABLE IF NOT EXISTS`, so applying one set and then the other is a safe no-op. | The claim I made was wrong in the direction that would have sent someone to "fix" a conflict that does not exist. **The real risk is the one the section now names: drift.** Two byte-identical trees with nothing enforcing that they stay so, and if a column ever lands on one side only, the cluster keeps whichever ran first while both trackers report head. That is unguarded today. Also restated at the point of use: ownership moved 2026-08-26 on `staging`/`development` only, so which copy is authoritative is **branch-dependent**. |


### Verified after the restructure

93 migration files (the count the step states). **59 runnable bash blocks, 0 syntax errors.** 40
tables across the touched files, 0 broken. `curl -s localhost:8123/ping` → `Ok.` against a live
server. `SharedMergeTree` rejection reproduced on 26.8.1.71.

### Known gaps after F6

- **Nothing in 7.4.3–7.4.5 has been executed.** The guard prevents the agent from running it and the
  only local cluster available was Fahmi's own, which must not be mutated for a test. The migration
  loop, the bootstrap `setup.sql` and both seeders are written from the files and **never run**.
- **This step edits `data-service`'s setup story**, which belongs to kemal, iru and arhen. Raised
  once, and Fahmi said proceed — this row is the receipt, not a re-argument. It should still be
  reviewed by them before the PR merges.
- **`data-service/README.md` §6 says the app serves `:8000`**; the framework registry and
  `run-all.sh` say `:9999`. Not chased, not in scope, unresolved.
- **No migration runner exists anywhere.** The loop in 7.4.4 is written inline in the skill, which
  means it is duplicated guidance rather than a tool. `database/migrate.py` remains the right home
  for it, and remains hypothetical.
- Everything open after `F3`, `F4` and `F5` is still open.

---

## 2026-08-27 — `F7`: what this branch knowingly ships broken

Pushed for testing on a second machine, **not** for merge. Two full `/onboard` trials were run against
freshly bootstrapped workspaces — one scoped to data-service + orchestration, one covering all five
services — and produced 39 findings. The defects below are the ones **this branch introduced** and has
not yet fixed. They are listed so the next person to read this, or to run `/onboard` from this branch,
is not debugging something already known.

**Do not merge this branch until the six ⛔ rows are closed.**

| # | Defect | Where | Status |
|---|---|---|---|
| ⛔ D1 | **No PostgreSQL deny rules.** `references/claude-settings.json` carries 32 denies — `clickhouse client`, every mutating `prefect` verb in both invocation forms, `*register_paid_deployments*`, `rm -rf`, force-push, `gh pr merge` — and **nothing for Postgres**, while Step 7.3 runs `dropdb <db_name> && createdb <db_name>` after one yes/no and then `php artisan migrate` against a user-typed name. The warehouse has nine guards; the database holding real data has none. Introduced by `F2`. | `skills/onboard/references/claude-settings.json` | open |
| ⛔ D2 | **Three of four ClickHouse databases are never created.** The 93 migration files write into `frnd_agg_marts`, `frnd_ai_database`, `frnd_os_master` and `temp_telkomsel_rafi`; only `frnd_os_master` has a `create_database.sql`. On the empty server 7.4.2 describes, 7.4.4 dies on the first `frnd_agg_marts` file. Compounded: `bootstrap/setup.sql` carries three `REVOKE ALTER, CREATE DATABASE, …` blocks against `frndos_data_service`, and 7.4.4 never says which user to run as. Proven statically. Introduced by `F6`. | `skills/onboard/SKILL.md` §7.4.3–7.4.4 | open |
| ⛔ D3 | **7.4.4's sort order is wrong and its premise is false.** The step claims the 93 files are "numbered **globally** across all databases so the run order is unambiguous" and sorts with `sort -t/ -k4`. Measured: `001` occurs 7 times, `007`–`010` five times each, and paths have **two depths** (25 at depth 4, 68 at depth 5), so `-k4` compares a filename against a `v1`/`v2` directory name. Output interleaves databases. The file *counts* in that step are correct; the ordering claim was invented. Introduced by `F6`. | `skills/onboard/SKILL.md` §7.4.4 | open |
| ⛔ D4 | **7.4.1 hands the agent a command this branch's own deny list blocks** — `clickhouse client --version`, two paragraphs after 7.4's ⛔ preamble declares it denied. Reproduced live: permission denied. Introduced by `F6b`, survived the `F6d` user-run pass. | `skills/onboard/SKILL.md` §7.4.1 | open |
| ⛔ D5 | **The Python 3.12 guard is on the wrong service.** `F5b` added the `PY312` resolver and its ⚠️ to **orchestration**, which installs and runs fine on 3.14 (measured: 1 failed / 236 passed). **data-service** — left on a bare `python3 -m venv` — hard-fails: `clickhouse-connect==0.9.2 Requires-Python >=3.9,<3.14`, leaving a venv with only `pip` in it. The reassurance "*measured on 3.14.6: 206 tests pass*" sits in a step covering both and is false for one. Introduced by `F5b`. | `skills/onboard/SKILL.md` §5.1–5.2 | open |
| ⛔ D6 | **Step 10 names a skill that does not exist.** It lists five orchestration skills including `metric-lineage`; `orchestration/.agents/skills/` on `staging` holds **four**, and `metric-lineage` has no directory anywhere in the repo — only prose in `pipeline-change/SKILL.md`, the ledger and a plan doc. It exists on `feature/fahmi/vc-insights-missing-metrics`, which is where it was read from. Same branch-dependence failure as `F1b` and `F3d`, committed a third time. The same paragraph also claims the skills "load the moment it is cloned" — they symlink into `orchestration/.claude/skills/`, invisible from a workspace-root session. Introduced by `F3e`. | `skills/onboard/SKILL.md` §10 | open |
| ⚠️ D7 | **Step 7.5.6's smoke test is unlabelled.** 7.5.3 and 7.5.5 are marked user-run; 7.5.6 runs `prefect deployment run`, denied in both invocation forms, and carries no label. | `skills/onboard/SKILL.md` §7.5.6 | open |
| ⚠️ D8 | **`steps.prefect_setup` is never written.** Both 7.4.5 and 7.5.6 say to record `steps.ch_local`; Step 7.5 never records its own key, which `F2b` defined. | `skills/onboard/SKILL.md` §7.5 | open |
| ⚠️ D9 | **7.6's seeder probe resolves its second candidate against the workspace root**, not `orchestration/`. Moot on `staging` — no seeder exists there — but wrong. | `skills/onboard/SKILL.md` §7.6 | open |
| ⚠️ D10 | **Step 12's port-conflict list omits `4200`, `8123` and `9000`.** `references/service-registry.md` says to add them "when either is in play"; the inline block in Step 12 — the one actually executed — never got them. Both ClickHouse ports were in use during the trial and invisible to the check. | `skills/onboard/SKILL.md` §12 | open |
| ⚠️ D11 | **`Bash(*register_paid_deployments*)` over-matches** — it blocked a read-only `ls scripts/`. Correct-erring, but it will confuse people. | `skills/onboard/references/claude-settings.json` | open |
| ⚠️ D12 | **`.claude/settings.json` is installed at Step 9** but cited as live protection from Step 6b onward. From 6b through 7.6 the commands this branch calls dangerous are unguarded, precisely while the skill walks you through them. Verified: `.claude/` holds only two symlinks at that point. Partly pre-existing (Step 9 owns the install), but every citation is this branch's. | ordering, `skills/onboard/SKILL.md` | open |

### Pre-existing defects the trials surfaced — NOT introduced here, not fixed here

Recorded because they are now known, and because one is destructive. **Step 10 destroys the framework's
own `prd` skill** (`npx skills add … --skill prd` overwrites `.agents/skills/prd/` and deletes its
`references/`, exit 0, green checkmark; in a non-git workspace it is unrecoverable). Then: `composer
install` fails because Step 5 forbids the `.env` it needs; two of five repos clone over SSH while Step 0
only verifies HTTPS; Step 12 asserts `401` for data-service where FastAPI returns `403`; `save_pid`
records the subshell so `--stop` falls back to killing by port and takes unrelated processes with it;
Steps 7.1/7.2 are Nix-only and print success after failing; `run-all.sh` preflight `.env` checks always
pass on an operator-precedence bug; `key:generate` silently rotates a supplied `APP_KEY` against a shared
database; `./run-all.sh` hangs under any output capture; `brew install mailhog` is impossible.

Two are worth a separate conversation with their owners rather than a fix here: **`ai-service/.env`
connects a laptop to shared staging as `doadmin`** and `run-all.sh` starts it on boot, and
**`run-all.sh` starts a queue worker against the real dev database**.

### Why this is pushed rather than merged

`README.md:379-384` makes `main` the distribution mechanism — merge, the Action bumps the manifest, and
workspaces pick it up; anyone cloning fresh and running `local-bootstrap.sh` gets it immediately. This
branch also moves orchestration's base and PR target from `main` to `staging` across 23 files, which is a
workflow change for that repo, not a documentation tweak. Testing on a second machine needs the branch,
not `main`.

## 2026-09-02 — `F8`: Prefect installation becomes an explicit, verified step

`F6` made ClickHouse a real step — install, start, migrate, seed. Prefect never got the first of
those. Its install was implicit in Step 5.2's `pip install -r requirements.txt` and mentioned only
inside a blockquote in 6b.2, so the first *named* Prefect action in the skill was "confirm the
profile" — a step that fails with command-not-found if the venv install did not land, pointing the
reader at the profiles file when the fault is the venv.

| # | What changed | Supersedes | Why | Cost |
|---|---|---|---|---|
| F8 | **Step 5.2 gains an orchestration-only verify block** — `orchestration/.venv/bin/prefect version` — stating that `requirements.txt:1` pins `prefect>=3.0.0` with an **open upper bound**, and recording the measured result (`3.8.3` on Python 3.12.13, 2026-09-02). | Nothing. Step 5.2 previously installed and verified nothing per-service. | An open upper bound means two machines onboarded a month apart get different Prefect versions from the identical command, and nothing in onboarding ever said so. Prefect is also the only service CLI the skill calls by path, so a silent install failure surfaces two steps later as a profile error. | One more command in Step 5.2. The pin itself is **not** changed — that is `frnd-orchestration`'s file and a different repo's decision. |
| F8a | **7.5.1 is renamed `Prefect — confirm the install, then the local profile`** and gains an install-confirmation half ahead of the profile half. States plainly that Prefect is not a system package, has no Homebrew row, and that 7.5 installs nothing. | `F3`/`F5`'s `7.5.1 Confirm the local Prefect profile`. | Mirrors 7.4.1, which does exactly this for the ClickHouse client. The asymmetry was the gap: ClickHouse's install is a named sub-step with two modes, Prefect's was a blockquote 300 lines earlier. **No renumbering** — 7.5.2–7.5.6 keep their numbers, so 6b's forward pointer at 7.5.3 and both `launch*.json` comments stay valid. | 7.5.1 now does two things under one heading. Accepted to avoid renumbering six sub-steps and every reference to them. |
| F8b | **The claim "there is no global `prefect` on a fresh machine" is corrected, not deleted.** 6b.2 now says a bare `prefect` fails on a fresh machine but may resolve to a *different install at a different version* on a machine that already does data work, and points at 7.5.1's ⚠️. | 6b.2's blockquote as written in `F2b`. | Measured, not assumed: `~/.local/bin/prefect` is **3.8.0** and `orchestration/.venv/bin/prefect` is **3.8.3** on the authoring machine — two installs, both reading the same `~/.prefect/profiles.toml`. The original sentence is true of a fresh machine and false of the machine most likely to select Orchestration. | Seventh stale claim corrected on this branch, and the first one that was **this branch's own**. The global default profile is `local`, so the failure mode is a wrong-version CLI rather than a wrong-estate one — but that is luck, not design. |

### Known gaps after F8

- **The repo-side local runtime is still not in the framework.** `frndos/scripts/local-seed-raw.py`
  (826 lines) and `local-run-pipeline.sh` (86 lines) remain gitignored at the workspace root. `F3b`'s
  gap 10 names `frnd-orchestration/scripts/seed_local_raw.py` as the destination; putting them in the
  framework instead is a **different decision** and is not taken here. See the fork put to Fahmi
  2026-09-02.
- **`local-run-pipeline.sh` needs the local Prefect server running** even though it triggers flows
  in-process: `PREFECT_PROFILE=local` sets `PREFECT_API_URL=127.0.0.1:4200`, so its
  `Secret.load('clickhouse-host')` guard returns empty with the server down and the script refuses
  with `clickhouse-host block is ''`. That reads as a bad block and is a stopped server. Not
  documented anywhere in the skill yet.
- **`D7` and `D8` from `F7` are untouched** — 7.5.6's smoke test is still unlabelled while calling a
  denied command, and 7.5 still records `steps.ch_local` rather than its own `steps.prefect_setup`.
- **The venv Python measured here is 3.12.13**, not the 3.14.6 `F5b` measured. Different trees:
  `F5b` measured a freshly bootstrapped test workspace, this measured `frndos/orchestration`. Both
  observations stand; the resolver in Step 5.1 is what makes them differ.

## 2026-09-02 — `F9`: Step 7.5 becomes runnable by a developer who has nothing

`F8` made the install explicit. The rest of 7.5 still assumed a developer who could already get
Secret-block values from Lark — so the first thing a new hire hit, two sub-steps in, was "ask fahmi
and wait". For a **pure local** estate none of those values are secret, and nobody had written that
down.

| # | What changed | Supersedes | Why | Cost |
|---|---|---|---|---|
| F9 | **7.5 opens with a prerequisite line and a six-line map of the whole path** — which terminal, which sub-step is user-run, roughly 15 minutes. | `F3`/`F5`'s 7.5, which began at 7.5.1 with no overview. | A developer could not see, before starting, that two processes stay running and that three sub-steps are handed back to them. The prerequisite is the sharper half: **7.4's local ClickHouse must be up first**, because every flow — the smoke test included — resolves ClickHouse from blocks and writes to it. Prefect starts fine without it and then nothing completes. | The map duplicates the sub-step headings; if 7.5 is ever renumbered again, two places change. |
| F9a | **7.5.3 gains a five-block "pure local" table with concrete values** — `clickhouse-host: localhost`, `clickhouse-port: 8123`, `clickhouse-user: default`, `clickhouse-pass:` *(empty)*, `environment: local` — declared sufficient for the 7.5.6 smoke test, with the Lark path demoted to "only if you need real API calls". | 7.5.3's "Minimum set to run an organic transform end to end" table, deleted; its content is split across the two new tables. | Verified in the code, not assumed: `get_client()` (`integrations/clickhouse.py:137-147`) passes a bare hostname through unchanged and defaults `secure=False`, and `resolve_environment()` (`:122-134`) returns the `environment` block verbatim. `testing_worker_flow` loads exactly those two functions. So a local developer needs **zero credentials** — the old table implied they needed Lark access to do anything. | The values are now hardcoded in the skill; if the local server's port or default user ever changes, the table is wrong rather than vague. `clickhouse-pass` must be created **empty rather than skipped** — `get_client()` loads it unconditionally — and that is easy to get wrong in a UI. |
| F9b | **The "server must be running" rule is stated where it bites.** `Secret.load(...)` is an API call to `127.0.0.1:4200`, not a file read. | Nothing — it was named only in `F8`'s gap list. | With the server down the call fails and the caller reads an empty value, so every symptom points at a missing block. This is exactly how `local-run-pipeline.sh` reports `clickhouse-host block is ''` when the real fault is a stopped server. | Stated in 7.5.3 only. The workspace-root run script that shows the same symptom is still not covered by this skill. |
| F9c | **7.5.5 now says what a local deployment source *is*.** `_make_source()` switches on `PREFECT_API_URL`: remote → a fresh `GitRepository` pinned to the environment's branch; **local → the repo root path**, so no clone, no branch pin, and a flow edit is live on the next run. | Nothing. | It is the reason a local estate is worth 15 minutes, and it was invisible. It also quietly answers a question `F1a` got wrong from a different direction: on a local server, branch is irrelevant because the worker reads your disk. | One more paragraph in an already long sub-step. |
| F9d | **`D7` and `D8` from `F7` are closed.** 7.5.6 is labelled **user runs this** with the reason inline, and it now records `steps.prefect_setup` — its own key — instead of `steps.ch_local`. | `F7`'s `D7`/`D8` rows, both `open`; and `F8`'s gap list, which said both were untouched. | `prefect deployment run` is denied in both forms and 7.5.6 called it with no label — the same defect `F3a` and `F6d` had already fixed twice elsewhere, left unfixed here. The key mix-up meant a completed Prefect setup was recorded as a completed ClickHouse setup. | Two of the twelve `F7` defects close. **The six ⛔ rows (`D1`–`D6`) remain open and the branch is still not merge-ready.** |
| F9e | **7.5.6 gains a read-back and a four-row failure table.** `curl` the smoke row count (agent-runnable, read-only); symptoms mapped to causes: run stuck `Pending` → no worker; `Secret.load` error → server down or block missing; connection refused → ClickHouse down; deployment not found → registered under a different profile. | Nothing — 7.5.6 previously ended at "watch it in the UI". | Every one of those four is a failure I hit or could reproduce from the code path. A new developer with no local Prefect experience reads "Pending" as "working". | The table is written from the code and from three of the four observed live; "deployment not found" is derived from `_make_source`'s profile switch, not observed. |

### Known gaps after F9

- **Not executed end to end on a clean machine.** The local estate on the authoring machine was built
  2026-07-27 and already holds 13 blocks, `local-pool`, six deployments and 334 flow runs — so 7.5
  was verified *against* a working estate, not *by* creating one. The `smoke-testing` deployment's
  last run there was 2026-07-27 and it Completed.
- **`prefect>=3.0.0`'s open upper bound still stands** (`F8`). 7.5's UI instructions assume the Blocks
  page layout of 3.8.x.
- **The `clickhouse-pass` empty-block trap is documented, not enforced.** Nothing verifies the five
  blocks exist before 7.5.5; `block ls` is offered but not gated.
- **`D1`–`D6` are untouched**, and `D9`–`D12` with them. This row closes `D7` and `D8` only.
- **The workspace-root runtime is still out of scope**: `local-seed-raw.py` and
  `local-run-pipeline.sh` remain gitignored at the workspace root. Per the 2026-09-02 comparison of
  all five services, they belong in `frnd-orchestration`, not here — four of five services seed from
  their own repo and orchestration is the only outlier.
