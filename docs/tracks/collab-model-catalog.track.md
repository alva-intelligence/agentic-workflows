---
title: Hocuspocus workspace support and model recommendation catalog
slug: collab-model-catalog
type: improvement
service: framework
status: in_progress
branch: improvement/vc-collab-model-catalog
created: 2026-11-05
scope_approved: true
implementation_approved: true
execution_mode: subagents
delivery: local_merge_push
pr_url: null
live_merge_approved: false
---

## Status

| Item | Status |
|---|---|
| PRD / service PRDs | n/a (framework improvement) |
| Plan | prepared |
| Implementation | completed |
| Verification | passed (targeted checks; limits below) |
| Delivery | local merge/push explicitly authorized (framework source only) |
| PR | not_required (explicit source-maintenance choice) |

This is the framework source checkout, not an installed service workspace. No synthetic
`.workflow-state.json` or onboarding state is created here; this track records task consent.

## Checkpoints

| Checkpoint | State | Authority | Date |
|---|---|---|---|
| Scope | approved | User selected **Both (Recommended)** in the scope question | 2026-11-05 |
| Implementation | approved | User selected **Implement both (Recommended)** | 2026-11-05 |
| Delivery | approved: local merge and push | User selected **Merge locally and push**; source-only exception, no PR; no protection bypass | 2026-11-05 |
| Live-estate merge | not_required | No data-pipeline or deployment changes in scope | |

The previous three-checkpoint task's consent did not carry over. The user separately selected
**Merge locally and push** for this task after independent verification. `local_merge_push` is a
framework-source maintenance choice recorded here, not a new service delivery enum. It authorizes
this source merge/publication only — no service/live-estate merge, deployment or protection bypass.

## Verified starting state

- Source base: `main` at `a95224617c02cecb982b49ee848395c2f28d0b00`, version `4.1.1`.
  Pulled latest before creating this improvement branch; no application code changed.
- Hocuspocus source: `alva-intelligence/frnd-hocuspocus` `main`
  at `0df71ea1d6c7ff19e94be7991c3bbd7f8fffb2de`.
- Frontend source: `frnd-web` `develop` at `4020418891da2cc862bc57cdc1cd64006c21e3cc`.
- API source: `frnd-api-php` `develop` at `ed3feff98ca724599fbb0c7b6b836d32672d35d2`.
- Four persisted Yjs room types: bare deck ID, `kv_file:`, `doc:`, and `studio:`.
  `proposal:`, `insight:` and `market:` are ephemeral presence rooms. The service README
  understates the current scope by omitting persisted Studio graphs.
- API owns migrations and JWT access/permission decisions; Hocuspocus authenticates through
  internal API callbacks and stores updates in that API's Postgres. Studio graph content lives
  only in its Yjs update log; the API reads live graphs and posts run/version facts over HTTP.
- Runtime uses `npm ci`, `npm run dev`, default port `1234`, `GET /health`. Although package
  engines say Node >=20, `src/config.ts` imports `loadEnvFile`, requiring Node >=20.12.
- Web config: `NEXT_PUBLIC_HOCUSPOCUS_URL`; API config: `COLLAB_URL` and
  `API_INTERNAL_TOKEN`; Hocuspocus: `API_BASE_URL` (including `/api`), `DATABASE_URL`,
  `X_INTERNAL_TOKEN` (matching the API token), with existing timeout/port knobs retained.
- Missing web collab configuration has non-persisted local Studio/deck paths; page rendering
  alone is not collaboration/persistence evidence. This is a conditional source finding,
  not an observed deployment incident. Application fixes are outside this change.
- Framework has no Hocuspocus references or central model catalog. Onboarding currently probes
  stale hardcoded Opus/Sonnet 5 identifiers. Workflow service maps already permit arbitrary
  service keys, so no state-schema expansion or legacy-state rewrite is needed for registration.

## Approved scope and decisions

1. Register `frnd-hocuspocus` as `hocuspocus/` / service key `hocuspocus`, matching its existing
   deployment directory and repository naming. Include by default for web/full-stack onboarding;
   allow skipping for unrelated setups, but require onboarding/configuration before work that
   needs live editing or presence. Never silently treat absence as working collaboration.
2. Cover onboarding selection/state, clone/install/env/start/health, generated run-all/launch
   configuration, service/branch routing, PRD/track examples, session checks and update guidance.
   Existing installs are informed of the new service; do not silently clone repos, rewrite envs,
   regenerate customized launch/run-all files, or assume old users opted in.
3. Hocuspocus feature branches and PRs use base `main`. This is a service-specific branch rule,
   not permission to push to main, bypass delivery consent, or deploy staging/production.
4. Ship one advisory `workflow/model-catalog.json` through the existing manifest/updater. No
   provider IDs, credentials, fixed agent roster, runtime model broker or background ranking job.
5. Resolve catalog labels against models the user's actual harness/account makes usable, using
   supported effort levels. Prefer existing user/provider choices; never invent API identifiers,
   enable another provider, silently switch the main model, or overwrite user configuration.
   When a preferred choice cannot be used, explain the available fallback without blocking work
   on an otherwise usable configured model.
6. On onboarding/session start and immediately after a framework update, review the catalog if
   not previously reviewed or its content digest changed. Summarize current recommendations
   once, check availability/effort, preserve explicit choices, then record a small cache marker.
   An unchanged catalog does not repeat the notice. Interrupted reviews remain unacknowledged.
   Catalog maintenance is curated and delivered through normal framework releases.

### Initial recommendations (user-specified)

| Role | Model | Effort | Recommendation |
|---|---|---|---|
| Main | Claude Opus 5.5 | high | strongly recommended |
| Main | GPT 6.1-Sol | xhigh | alternative |
| Subagent | DeepSeek V4.1 Flash | max | strongly recommended |
| Subagent | GLM 5.3 Flash | max | alternative |
| Subagent | Claude Sonnet 5.5 | xhigh | alternative |
| Subagent | GPT 6.1-Terra | xhigh | alternative |

Current harness metadata lists the first five model/effort pairs, not Terra. Only the configured
DeepSeek subagent path was exercised by these actual tasks; no paid availability probes were run.
This is session-local evidence, not a claim that Terra is globally absent; the catalog is advisory.

## Implementation plan

- [x] **TASK-1 — Hocuspocus integration (medium risk; auth/env handling high-impact).**
  - Plan: update service registry/core fragments, onboarding and its run-all/launch references,
    session health/recency checks, Git/PRD/track service mappings and relevant README/update
    guidance. Reuse existing optional-service patterns; include Hocuspocus by default when web
    is selected. Respect custom settings, existing state, shared infrastructure and runtime knobs.
  - Verification: shell syntax and existing checks; minimal fixture checks for service selection,
    main base routing, start/health registration and safe lifecycle. Verify URL/token guidance
    without printing secrets or contacting live services. Document two-client sync/reload
    acceptance checks, but do not claim them run without an isolated app workspace.
  - Evidence: isolated service branch integrated; parent corrected native env/PORT parsing,
    protected shared/reserved ports, secret-equality guidance, stale owner/instruction assumptions,
    service selection and legacy-update hooks. Existing and expanded checks pass, including native
    quoted/exported/default/ambient/invalid PORT cases and task-owned stub start/status/stop.
    No real app, shared infrastructure or live estate was started/stopped.
- [x] **TASK-2 — Model catalog and review notices (medium risk).**
  - Plan: add the small role catalog and provider-independent selection/review guidance in
    onboarding, setup, orchestration/session/update instructions; replace obsolete mandatory
    model probes. Use a content-digest cache marker only for review/notification bookkeeping,
    not new workflow consent or user-provider configuration.
  - Verification: stdlib assertions for catalog shape, one strongly recommended pair per role,
    supported effort vocabulary, manifest target and guidance wiring; runnable check for first,
    unchanged, changed and interrupted-review behavior if any helper logic is introduced.
    Check unavailable-model/unsupported-effort fallback and preservation of explicit choices.
  - Evidence: integrated the isolated catalog branch, reduced catalog to recommendation data only,
    corrected per-task selection and reviewed-digest race guidance, wired shared entry points.
    `python3 scripts/check-workflow.py` now exercises first/unreviewed/reviewed/changed/offline
    updater cases in fresh/cached fixtures, confirms the updater never acknowledges reviews and
    preserves workflow/onboard/custom permission files. Catalog/schema wiring, shell syntax and
    manifest coverage pass; final whole-change review remains TASK-3.
- [x] **TASK-3 — Integration, upgrade verification and review (medium risk).**
  - Plan: main agent integrates isolated task branches, reconciles shared onboarding/session
    edits, updates release metadata/manifest and generated AGENTS.md, then reconciles TODO.
    Keep source checks in the existing small check file; add no dependencies or test framework.
  - Verification: run both existing Python checks, manifest hashes, shell syntax, error-severity
    ShellCheck when available, and diff checks. Use fresh and cached-4.1 updater fixtures to
    verify catalog delivery, generated instructions, repeated-update convergence and byte-for-byte
    preservation of workflow/onboard/custom permission files. Use task-owned stubs/resources
    only; never start, stop or mutate shared Postgres/Redis/Prefect or a live deployment.
    Fresh-eyes adversarial review followed by the main agent's personal whole-change/security
    review; reproduce findings rather than trusting a subagent completion message.
  - Evidence: final candidate a642004 passes both Python checks, 38 manifest hashes, shell syntax,
    error-severity ShellCheck and diff checks. Authentic cached 4.1.1 → 4.2.0 and fresh installs
    pass (76 installed hashes, exact generated instructions, seven user-owned state/custom/env
    files unchanged, no service auto-clone or auto-acknowledgment). Full and focused independent
    adversarial reviews completed; findings reproduced/resolved. Main agent completed the final
    whole-change/security review with no remaining must-fix or high/critical finding in scope.

## Execution and boundaries

Resolved execution: `subagents`, explicitly approved by the user's implementation choice. Two
bounded isolated implementation tasks (service integration and model catalog), followed by
main-agent integration/verification and a fresh reviewer. Check CPU/memory/disk before intensive work. Each task owns
its exact file scope and verification evidence; no subagent asks the user or authorizes delivery.

Excluded: application fallback fixes, live env/secrets changes, deployment, live model discovery,
new library/test dependencies, provider adapters, generated agent definitions and unrelated updater
rewrites. CI pins the service's already-required Node 22 runtime for the native-env fixtures.
Rollback: discard/revert this source change before delivery; installations retain their previous
service selection/settings. Review markers are derived cache only and confer no authorization.

## Verification log

### 2026-11-05 — Baseline on source base a952246

- `python3 scripts/check-workflow.py`: passed checkpoint/metadata/schema-default/merge/generator checks.
- `python3 scripts/check-manifest-coverage.py`: passed (37 declared entries, 38 distributed tracked
  files including two check exclusions).
- Manifest SHA-256 verification: all 37 entries matched their source files.
- `bash -n scripts/update-check.sh` and `bash -n scripts/generate-agents.sh`: passed.
- `git diff --check`: passed before this planning document.
- Direct pinned source checks corroborated the external trace's Studio auth, live-document HTTP
  client, local-only/save-gate behavior and deck fallback. No app code/tests/deployments executed.

### 2026-11-05 — Candidate e230c63 and adversarial follow-up

- Both Python checks pass; 38 manifest source hashes match, shell syntax and error-severity
  ShellCheck pass. The expanded existing assert file uses only stdlib plus the service's Node
  runtime; no framework/test packages were added. Native `/bin/bash` 3.2 syntax and a PATH-first
  native-Bash regression run also pass.
- Mocked-local fresh install and an authentic original cached 4.1.1 updater both install candidate
  e230c63. Verified all 38 target hashes in each (76 total) and exact generated AGENTS.md 4.2.0.
  Workflow/onboard state, custom permissions, launch configuration, run-all and two mock env files
  stay byte-identical. No Hocuspocus directory is cloned and no reviewed marker is written.
- The original cached updater cannot emit new helper logic on its first invocation; the updated
  generator emits the read-regenerated-AGENTS/model-review reminder. Subsequent current-updater
  calls preserve an unacknowledged notice and become quiet only after a simulated completed
  digest review. Current-source fixtures also cover changed and offline notices without acknowledgment.
- Full independent adversarial review reproduced an unsafe new port sweep. Removed Hocuspocus
  from blanket kill ports; only its recorded PID/start-time/PGID process group can receive TERM.
  Regression fixtures leave an unrelated listener and stale/reused PID group alive, skip occupied
  startup, and stop both the task-owned npm-style parent and its child. Shared infrastructure was
  never started/stopped. Existing fixed-port behavior for other services is not reworked here.
- An unconfigured optional repo now warns/skips, not blocks unrelated apps. Missing-env and invalid
  startup cases pass; collaboration remains unavailable/pending until its actual checks pass.
  Native ambient PORT precedence is retained/documented and the validated value is pinned at launch.
- Removed stale provider/model-role names from active onboarding. Added secure local-file env
  handling and preserved existing APP_KEY; no secrets were read or transferred for this task.
  Hocuspocus PRD section/base example and SHA-pinned Node22 CI runtime complete the integration.
  Retired model probes and env upload/key-generation instructions are bannered in the ledger.
- The reviewer's older local Hocuspocus checkout lacked Studio/Market. Authenticated GitHub GET
  reconfirmed pinned commit 0df71ea1d6c7ff19e94be7991c3bbd7f8fffb2de exists; cached source includes
  StudioPersistence and Market presence. Older local refs do not supersede the pinned investigation.
- Marker accepts the specified bare SHA-256 digest; arbitrary checksum output is intentionally not
  normalized into an acknowledgment. The permanent cached fixture exercises cached-path execution,
  not an authentic old binary; the separate real-old-updater test above covers this release.
- Two-client collaboration/reload, actual app/database integration, deployment health and unexercised
  model-account access remain untested. No remote CI run is claimed before delivery/push consent.
- Release evidence: `/tmp/aw-collab.K81NTc/` (local fake remotes, fresh/upgraded workspaces and logs).
  These are task-owned fixtures, not service workspaces or live state. No task-owned Chrome started.

### 2026-11-05 — Final candidate a642004; delivery checkpoint

- Focused independent post-fix review found no lifecycle defect. Its six throwaway mutation checks
  demonstrated the regression assertions catch unsafe port sweeps, absent group creation, missing
  start-time validation, missing validated-PORT pin, PID-only shutdown and occupied-port launches.
  Main re-ran the resulting unmodified check and inspected the final whole diff personally.
- The review's two documentation findings are fixed: remaining GitHub/Figma/Sentry token-paste
  prompts now use local authentication/configuration, and ledger rows are contiguous in their table.
  Verified retired active prompts are absent and the final targeted diff/ledger structure is correct.
- Repeated real-old-cached-updater and fresh installation tests for final candidate a642004: all
  76 target hashes/exact generated AGENTS match; seven user files unchanged; no clone or review ack.
  Both Python checks, error-severity ShellCheck and diff checks pass. Documented command syntax:
  77 Bash blocks pass; 12 non-runnable placeholder examples deliberately skipped.
- Residual lifecycle ceiling is intentional fail-closed behavior: untracked listeners, an orphaned
  group without a verifiable live leader, or a TERM-resistant process require manual inspection.
  No automatic broad port kill or SIGKILL escalation is added. Real app persistence remains untested.
- Original request/TODO reconciled: service integration and updateable advisory catalog are complete.
  The user subsequently authorized source-only local merge/push. Fresh checks show a clean topic
  branch, local main and origin/main both a952246, admin/push access, protected=false and no effective
  main branch rules. No protection bypass is needed. Publication fulfillment is verified against
  the remote SHA after the normal push; no application deployment is included.

## Session log

### 2026-11-05 — Preparation

User approved both scopes. Created `improvement/vc-collab-model-catalog` from freshly pulled main.
Only this plan/track was added before implementation approval. The user then explicitly selected
**Implement both (Recommended)**. Implementation is now authorized; delivery remains unchosen.
