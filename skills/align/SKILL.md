---
name: align
description: Put every service repo on the right branch for the active feature — in-scope services on the feature branch, everything else parked on its default branch. Run on every context switch, at session start, or whenever the workspace feels scattered.
---

# Align

One feature means **one branch name in every in-scope service** and **the default branch in
every uninvolved one**. This skill is the refresh button for that invariant.

The rule is not new — `AGENTS.md` rules 3, 6 and 7, "Branch Naming" and "Default Branches by
Service" all state it. What was missing until ledger `W16` was a verb that performs it, so
five repos drifted onto five unrelated branches under one active feature.

Everything here is a thin wrapper over `scripts/local-align.sh`. The script decides nothing:
scope, branch name and service list all come from `.workflow-state.json`, written during
`prd_splitting`.

## Commands

### `/align` — show the drift (default, read-only)

```bash
./scripts/local-align.sh
```

Prints a table of SERVICE / CURRENT / EXPECTED / STATE and exits **1** on drift, **0** when
aligned. Nothing is moved.

Present the table verbatim. Then, for each row that is not `ok`, say in one line what it means:

| STATE | Reading |
|---|---|
| `ok (in)` | In scope, on the feature branch. Nothing to do. |
| `ok (out)` | Out of scope, parked on its default branch. Nothing to do. |
| `DRIFT (in)` | In scope but on the wrong branch — work would land in the wrong place. |
| `DRIFT (out)` | Out of scope but still on some feature branch — leftover from a past context. |
| `BLOCKED — tracked changes` | Uncommitted tracked edits. **Fahmi commits or stashes; never do it for him.** |
| `BLOCKED — release branch` | On a `release/*` branch, possibly in review. `--force-release` steps off; the branch and its PR survive. |
| `pinned (never moved)` | `workspace-root`. It is `agentic-workflows` on a long-lived personal branch and is reported only. |
| `MISSING (not cloned)` | Service directory absent. Onboarding gap, not drift. |

Finish with the one concrete next step — usually `/align apply`.

### `/align apply` — move the branches

```bash
./scripts/local-align.sh --apply
```

In-scope services are checked out (or created) on `features[<slug>].branch`; every other
service is checked out on its own default branch and fast-forwarded. Never pushes, never
merges, never stashes.

Before running, state which repos will move and where. After running, show the output and
re-run the read-only check to confirm `aligned.`

Anything still `BLOCKED` is **reported, not worked around**. Do not `git stash`, do not
`--force-release` on your own initiative — say what is blocked and let Fahmi choose.

### `/align <slug>` — check or align against a different feature

```bash
./scripts/local-align.sh <slug>
./scripts/local-align.sh <slug> --apply
```

Answers "what would the workspace look like if I switched to this feature?" without switching.
For an actual context switch use `/workflow switch <slug>`, which runs this as its step 6.

### `/align wire` — restore the local-only wiring

```bash
./scripts/local-align-wire.sh --check    # report what is missing
./scripts/local-align-wire.sh            # restore it
```

`.agents/`, `.claude/` and `.agentic-workflows/` are gitignored install artifacts that
`local-bootstrap.sh` and `update-check.sh` overwrite. `AGENTS.md` is generated, never edited —
and `generate-agents.sh` reads the **cached** fragments, not the tracked ones.

Two different repair strategies, deliberately:

| Target | How | Why |
|---|---|---|
| `skills/align/`, `scripts/hooks/align-guard.sh` | **copied** over the install copy | Wholly ours; no upstream version to clobber |
| `/workflow`, `/prd-split`, the AGENTS.md fragments | **patched** in place, marker-guarded | These exist upstream and are also patched by `local-worktree-mode.sh` and `local-wire-orchestration.sh`. Copying reverts their work — measured 2026-09-02: it reinstated the legacy "JJ workspace" text in Step 0 and dropped `orchestration/` from Step 0.5. |
| the `PreToolUse` entry in `.claude/settings.json` | appended if absent | Other entries and the orchestration production guard are preserved |

`AGENTS.md` is regenerated automatically when a fragment is patched.

Run it after **any** bootstrap or update-check, alongside `scripts/local-wire-orchestration.sh`
and `scripts/local-worktree-mode.sh`.

## The guard

`.claude/hooks/align-guard.sh` is a `PreToolUse` hook on `Edit|Write|NotebookEdit`. It refuses
an edit into a service repo that is on the wrong branch and names three ways out: align, start
a separate feature, or `FRNDOS_ALIGN_OFF=1`.

**If the guard fires, do not route around it.** Report which repo, which branch, which expected
branch, and ask. Using the escape hatch is a decision to state out loud, not a workaround to
apply quietly.

**Known gap, and it matters:** the guard is blind to Bash-driven writes — `sed -i`,
`cat > file <<EOF`, `python3 - <<PY` never reach `PreToolUse` on `Edit`/`Write`. When editing
through Bash, check the branch yourself first.

## When the answer is a new feature, not an alignment

If Fahmi asks for something that has nothing to do with the active feature, the honest move is
**not** to create a branch in one repo. It is:

- `/workflow start <slug>` → brainstorm → PRD → `prd_splitting` creates the branch → `/align apply`, or
- `/jj-workflow new <slug>` for a parallel worktree when both features need to stay live.

Ad-hoc single-repo branches are how the drift happened. Two of them
(`fix/fahmi/vc-worker-requirements-drift`, `release/fahmi/insights-metrics`) still have no
feature entry in `.workflow-state.json`.

## Scope comes from state, not from judgement

`scripts/local-align.sh` reads:

- `features[<slug>].branch` — the one branch name
- `features[<slug>].services` — the in-scope list, as workspace **directory** names
  (`orchestration`, not `frnd-orchestration`); falls back to `service_prds` keys
- `.onboard-state.json` `services` — the full roster
- each repo's `origin/HEAD` for its default branch, with an `AGENTS.md` fallback table
  (api/web `develop`, ai-service/data-service `development`, orchestration `main`)

If `services` is `null` **and** `service_prds` is empty, the feature has no scope and the guard
is effectively off. That is a `prd_splitting` bug — fix it there, not here.

## Never

- Never `git stash` on Fahmi's behalf to unblock a move.
- Never push or merge from this skill. `orchestration`'s `main` deploys staging **and**
  production at once (`AGENTS.md` "Default Branches by Service").
- Never move `workspace-root`.
- Never edit `.agents/skills/align/SKILL.md` — that is the install copy. Edit
  `skills/align/SKILL.md` and run `/align wire`.
