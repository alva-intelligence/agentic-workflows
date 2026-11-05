---
title: Three-checkpoint workflow
slug: three-checkpoint-workflow
status: in_progress
branch: improvement/vc-three-checkpoint-workflow
created: 2026-11-05
---

## Approved scope

Three checkpoints: scope, implementation, delivery. Automatically prepare feature PRDs/splits/plans
after scope approval. Bugs/improvements skip comprehensive PRDs. Features/improvements default to
subagents; bugs/hotfixes to main, with overrides. Keep orchestration harness-agnostic.

Implementation was explicitly authorized by “ok aggreed on all. Do it”. Delivery remains unchosen:
no push, PR, merge, or production action is authorized by that implementation instruction.

## Plan and verification plan

| Task | Plan | Expected evidence |
|---|---|---|
| Policy/state | Retain existing phases and required state; add optional conservative consent fields and checkpoint metadata | Exact checkpoint/transition/gate assertions; real schema accepts legacy and new state, rejects malformed consent |
| Skills/templates | Remove document-by-document approvals; retain scoped plans, targeted regression checks, independent and personal final reviews | Whole-change review against the original request; no early push or manual-test completion shortcuts |
| Delivery/migration | Per-task opt-in, current-head merge gate, bounded review watch, separate live-estate consent; preserve existing state/settings | Read-only GraphQL query; head-match command support; fresh and old-cached-updater installation checks with byte-for-byte state preservation |
| Documentation/release | Update diagrams/ledger/README; generate instructions; refresh release metadata | SVG render inspection, JSON/XML/shell checks, manifest coverage and hashes, repeat install convergence |

Risk: medium overall; merge authorization and live-estate safeguards are high-impact. No actual
merge or live deployment is used as a test. No new dependency or workflow runtime is added.

## Verification evidence

- Real installed `jsonschema` validator: legacy state without new flags and explicitly populated
  new state both accepted. Invalid execution mode, unknown automation flag, string consent, and
  invalid delivery rejected (six cases; all expected outcomes).
- Read-only public GraphQL query against `cli/cli#14927`: paginated review-thread query with nested
  `comments.totalCount` accepted; returned four threads. Nested comment pagination is a separate
  query, avoiding competing cursors in the outer pagination.
- `gh pr merge --help`: installed CLI supports `--match-head-commit`.
- `python3 scripts/check-workflow.py`: passed checkpoint/edge/gate/schema-default/merge-policy
  assertions and real fresh/upgrade generator regressions.
- `python3 scripts/check-manifest-coverage.py`: passed (37 declared entries, root VERSION included;
  two repo-only check exclusions). All 37 source SHA-256 entries matched.
- Real installer smoke: bootstrapped committed v4.0.0 (`5ca6f94`) into a disposable workspace,
  then invoked its cached updater against the v4.1.0 candidate through a local fake remote.
  Also bootstrapped a separate fresh workspace. Both generated exactly the source AGENTS.md with
  header/cache version 4.1.0. Verified 74 installed hashes (37 per workspace).
- Existing `.workflow-state.json`, `.onboard-state.json`, and custom
  `.claude/settings.local.json` remained byte-for-byte identical: no inferred authorization or
  silent merge-permission changes. Repeated normal checks reported already up-to-date; final
  bootstrap/hash checks included the last documentation corrections.
- Six real JSON Schema cases passed their expected accept/reject outcomes. Seven current/legacy
  branch-name examples passed their expected match/non-match outcomes.
- `bash -n` passed both installer/generator scripts and 17 shell examples from the visual-testing,
  PR-feedback, and update skills. Error-severity ShellCheck passed. Full ShellCheck still has
  three pre-existing warnings in the unchanged updater (SC2034/SC2059), not newly introduced errors.
- Both SVGs passed `xmllint`, rendered in isolated headless Chrome driven by browser-use, and were
  personally inspected. No text exceeded either viewBox; the overlapping intercom caption was
  corrected. Owned tabs, daemon, Chrome process, and temporary profile were stopped/removed.
- `git diff --check`: passed. No new dependency, queue, daemon, or workflow execution engine.

## Review

Main-agent adversarial passes corrected: local testing falsely completing delivery; implementation
approval allowing early push; merge head-SHA race; nested pagination ambiguity; stale opt-in-only
test instructions; stale phase-status semantics; and first-install/update instruction-version header.

Independent read-only adversarial review returned six findings. Main-agent verification corrected
all six: unconditional push example, inconsistent brainstorming-skip consent, inconsistent watch
fields/statuses, missing canonical head pin, incomplete feedback gates, and stale test-note wording.
The test-note issue had already been corrected during review. The implementation gate now also
requires all scoped tasks/acceptance criteria complete or explicitly user-deferred, not one checkbox.

Final whole-change review completed by the main agent against the original request: policy,
state/gates, skills/templates, permission migration, diagrams, release hashes, and actual installer
outputs reconciled. Also corrected misleading human-merge example, broken-link verification,
legacy branch discovery, and isolated/named headless-browser setup. Existing CI check job ID was
preserved so this update does not rename a required check. No unresolved must-fix finding remains.

Re-run the persistent core checks from the repository root:

```bash
python3 scripts/check-workflow.py
python3 scripts/check-manifest-coverage.py
jq -r '.files | to_entries[] | "\(.value.sha256)  \(.key)"' manifest.json | shasum -a 256 -c -
bash -n scripts/update-check.sh && bash -n scripts/generate-agents.sh
xmllint --noout docs/agent-architecture.svg docs/workflow-state-machine.svg
git diff --check
```

Disposable smoke logs, fixtures, and screenshots for this run: `/tmp/aw-release.TxnBnI/`.
They are evidence artifacts, not installed workspace files.

## Limits and delivery

These are reproducible verification results, not mathematical formal verification. No real
reply/resolve/merge mutations or production actions are exercised. A full autonomous agent session
on every supported harness is not simulated by declarative checks.

Source-maintenance delivery explicitly authorized by the user: “merge locally and opush”.
Merge this verified branch into this instruction repository's `main`, then make a normal push.
No PR was requested. This is a source-repository delivery instruction, not a new service-workflow
`delivery` enum or permission to merge/deploy a service. GitHub reports `main` unprotected and no
applicable branch rules; no protection is disabled or bypassed. Remote-head verification follows
the push; the source track remains in progress until that delivery is observed.
