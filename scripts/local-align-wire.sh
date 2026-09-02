#!/usr/bin/env bash
# local-align-wire.sh — reinstall the W16/W17 alignment wiring from its tracked sources.
#
# `.agents/`, `.claude/` and `.agentic-workflows/` are gitignored install artifacts
# (.gitignore:8-11). A bootstrap, an update-check, or a skills re-install overwrites them, and
# every local patch to a skill, hook, settings entry or AGENTS.md fragment is lost.
#
#   skills/align/                -> .agents/skills/align/         (the /align skill)
#   skills/workflow/             -> .agents/skills/workflow/      (switch step 6, status step 3)
#   skills/prd-split/            -> .agents/skills/prd-split/     (steps 9, 9b)
#   scripts/hooks/align-guard.sh -> .claude/hooks/align-guard.sh
#   + the PreToolUse entry in .claude/settings.json
#   + Step 1 / Step 4 / rules 6-7 patched into the CACHED AGENTS.md fragments, then a regen
#
# AGENTS.md is generated, never edited. generate-agents.sh prefers the gitignored
# .agentic-workflows/ cache over tracked agents/, so this script PATCHES the cached fragments
# in place, marker-guarded. It must NOT copy tracked fragments over them:
# local-worktree-mode.sh and local-wire-orchestration.sh patch those same files, and a
# wholesale copy reverts their work (measured 2026-09-02 — it reinstated the legacy
# "JJ workspace" text in Step 0 and dropped orchestration/ from Step 0.5).
#
# Idempotent. Run after ANY bootstrap or update-check, alongside the other two wire scripts.
#
#   ./scripts/local-align-wire.sh            # restore
#   ./scripts/local-align-wire.sh --check    # report what is missing, change nothing

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

missing=0
REGEN=0
note() { echo "  $*"; }
need() { missing=1; note "STALE: $*"; }

# ---------------------------------------------------------------- skills
# `align` is entirely ours — no upstream version exists, so a straight copy is safe.
# `workflow` and `prd-split` DO exist upstream: they are PATCHED in place, marker-guarded.
# Copying our tracked copy over them would silently revert any upstream update — the same
# failure this script hit on the AGENTS.md fragments (see header).
src="skills/align"; dst=".agents/skills/align"
if [ ! -d "$src" ]; then
  note "SKIP (no tracked source): $src"
elif [ ! -d "$dst" ] || ! diff -rq "$src" "$dst" >/dev/null 2>&1; then
  need "$dst"
  if [ "$CHECK" = "0" ]; then
    mkdir -p "$dst"
    (cd "$src" && find . -type f -print0) | while IFS= read -r -d '' f; do
      mkdir -p "$dst/$(dirname "$f")"; cp "$src/$f" "$dst/$f"
    done
    note "installed $src -> $dst"
  fi
fi

S_WORKFLOW=".agents/skills/workflow/SKILL.md"
if [ -f "$S_WORKFLOW" ] && ! grep -q "local-align" "$S_WORKFLOW"; then
  need "$S_WORKFLOW"
  if [ "$CHECK" = "0" ]; then
    python3 "$ROOT/scripts/hooks/patch-workflow-skill.py" "$S_WORKFLOW" && note "patched $S_WORKFLOW"
  fi
fi

S_SPLIT=".agents/skills/prd-split/SKILL.md"
if [ -f "$S_SPLIT" ] && ! grep -q "local-align" "$S_SPLIT"; then
  need "$S_SPLIT"
  if [ "$CHECK" = "0" ]; then
    python3 "$ROOT/scripts/hooks/patch-prdsplit-skill.py" "$S_SPLIT" && note "patched $S_SPLIT"
  fi
fi

# ---------------------------------------------------------------- hook
HOOK_SRC="scripts/hooks/align-guard.sh"; HOOK_DST=".claude/hooks/align-guard.sh"
if [ ! -f "$HOOK_SRC" ]; then
  note "SKIP (no tracked source): $HOOK_SRC"
elif [ ! -f "$HOOK_DST" ] || ! cmp -s "$HOOK_SRC" "$HOOK_DST"; then
  need "$HOOK_DST"
  if [ "$CHECK" = "0" ]; then
    mkdir -p .claude/hooks && cp "$HOOK_SRC" "$HOOK_DST" && chmod +x "$HOOK_DST"
    note "installed $HOOK_SRC -> $HOOK_DST"
  fi
fi

# ---------------------------------------------------------------- settings.json entry
if [ -f .claude/settings.json ] && ! python3 -c '
import json, sys
h = (json.load(open(".claude/settings.json")).get("hooks") or {}).get("PreToolUse") or []
sys.exit(0 if any("align-guard" in str(e) for e in h) else 1)
' 2>/dev/null; then
  need ".claude/settings.json PreToolUse -> align-guard.sh"
  if [ "$CHECK" = "0" ]; then
    python3 - <<'PYSET'
import json, collections
p = ".claude/settings.json"
s = json.load(open(p), object_pairs_hook=collections.OrderedDict)
entry = collections.OrderedDict([
    ("matcher", "Edit|Write|NotebookEdit"),
    ("hooks", [collections.OrderedDict([
        ("type", "command"),
        ("command", "$CLAUDE_PROJECT_DIR/.claude/hooks/align-guard.sh"),
    ])]),
])
pre = s.setdefault("hooks", collections.OrderedDict()).setdefault("PreToolUse", [])
if not any("align-guard" in str(e) for e in pre):
    pre.append(entry)
json.dump(s, open(p, "w"), indent=2, ensure_ascii=False)
open(p, "a").write("\n")
PYSET
    note "wired .claude/settings.json"
  fi
fi

# ---------------------------------------------------------------- AGENTS.md fragments
FRAG_DIR=".agentic-workflows/fragments"
[ -d "$FRAG_DIR" ] || FRAG_DIR="agents/fragments"

F_SESSION="$FRAG_DIR/session-protocol.core.md"
F_RULES="$FRAG_DIR/workflow-rules.core.md"

if [ -f "$F_SESSION" ] && ! grep -q "local-align" "$F_SESSION"; then
  need "$F_SESSION"
  if [ "$CHECK" = "0" ]; then
    python3 - "$F_SESSION" <<'PYSESS'
import sys
p = sys.argv[1]
s = open(p).read()
old = "### Step 4: Feature branch recency + service health"
new = """### Step 4: Workspace alignment + feature branch recency + service health

**First, run `./scripts/local-align.sh` (read-only), or `/align`.** It exits 1 and prints a
table when any service is on the wrong branch for the active feature. Show the table and
resolve the drift before starting work — `--apply` moves the movable repos; anything marked
`BLOCKED` is resolved by hand, never worked around. One feature means one branch name in every
in-scope service and the default branch in every uninvolved one."""
if old in s:
    s = s.replace(old, new, 1)

anchor = "### Step 2: Load workflow state"
block = """**After any bootstrap or update-check, re-apply the local-only wiring.** `.agents/`,
`.claude/` and `.agentic-workflows/` are gitignored install artifacts that `local-bootstrap.sh`
and `update-check.sh` overwrite, and `AGENTS.md` is reassembled from the cached fragments.
Every local patch to a skill, hook, settings entry or fragment is lost unless it is restored.
Three tracked scripts do that — run all three, each is idempotent and each takes `--check`:

| Script | Restores |
|---|---|
| `scripts/local-wire-orchestration.sh` | `orchestration/` registered as the fifth service |
| `scripts/local-worktree-mode.sh` | `/jj-workflow` delegating to git worktrees (ledger `W1`) |
| `scripts/local-align-wire.sh` | `skills/align`, the `/workflow` + `/prd-split` steps, the `align-guard` hook and its `settings.json` entry (ledger `W16`, `W17`) |

"""
if anchor in s and "local-align-wire.sh" not in s:
    s = s.replace(anchor, block + anchor, 1)
open(p, "w").write(s)
PYSESS
    note "patched $F_SESSION"; REGEN=1
  fi
fi

if [ -f "$F_RULES" ] && ! grep -q "local-align" "$F_RULES"; then
  need "$F_RULES"
  if [ "$CHECK" = "0" ]; then
    python3 - "$F_RULES" <<'PYRULE'
import sys
p = sys.argv[1]
s = open(p).read()
old = """6. **CHECK current git branch matches the expected branch for the phase** before doing any work.
7. **Wait for user before advancing.**"""
new = """6. **CHECK current git branch matches the expected branch for the phase** before doing any work.
   Mechanically: `/align`, or `./scripts/local-align.sh`. The `align-guard` PreToolUse hook
   (`.claude/hooks/align-guard.sh`) blocks Edit/Write into any service repo that is on the
   wrong branch. If it fires, either align or start a separate feature — do not disable it
   silently. `FRNDOS_ALIGN_OFF=1` is the escape hatch and using it must be stated out loud.
7. **Work that is unrelated to the active feature gets its own slug.** `/workflow start <slug>`
   (or `/jj-workflow new <slug>` for a parallel worktree), then align. Never an ad-hoc branch
   created in one repo — that is exactly how five repos ended up on five unrelated branches.
8. **Wait for user before advancing.**"""
if old in s:
    s = s.replace(old, new, 1)
open(p, "w").write(s)
PYRULE
    note "patched $F_RULES"; REGEN=1
  fi
fi

if [ "$REGEN" = "1" ] && [ -f scripts/generate-agents.sh ]; then
  if bash scripts/generate-agents.sh >/dev/null 2>&1; then
    note "regenerated AGENTS.md"
  else
    note "WARNING: generate-agents.sh failed — AGENTS.md may be stale"
  fi
fi

if [ -f AGENTS.md ] && ! grep -q "local-align.sh" AGENTS.md; then
  missing=1
  note "STALE: AGENTS.md has no alignment text — run scripts/generate-agents.sh"
fi

echo
if [ "$missing" = "0" ]; then
  echo "align wiring: present."
elif [ "$CHECK" = "1" ]; then
  echo "align wiring: INCOMPLETE — run ./scripts/local-align-wire.sh"
  exit 1
else
  echo "align wiring: restored."
fi
