#!/usr/bin/env bash
# local-align.sh — make every service repo agree about which feature is being worked on.
#
# One feature = one branch name in every in-scope service; every out-of-scope service
# parks on its own default branch. Read-only by default.
#
#   ./scripts/local-align.sh                  # check the active feature (read-only, exit 1 on drift)
#   ./scripts/local-align.sh <slug>           # check a named feature
#   ./scripts/local-align.sh --apply          # actually move the branches
#   ./scripts/local-align.sh <slug> --apply
#   ./scripts/local-align.sh --expected <dir> # print one repo's expected branch (used by the hook)
#   ./scripts/local-align.sh --apply --force-release   # also step off a release/* branch
#
# Never pushes. Never merges. Never stashes. Refuses on tracked-file changes.
# Scope, branch name and service list all come from .workflow-state.json — this script
# decides nothing, it only enforces what prd_splitting already recorded.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STATE=".workflow-state.json"
ONBOARD=".onboard-state.json"

# workspace-root is a member of service_prds but is NOT a per-feature checkout: it is
# agentic-workflows on a long-lived personal branch, and docs/prd/local-pipeline-e2e.workspace-root.md
# says so explicitly ("commits land on the workspace-root branch fahmi keeps"). Report, never move.
PINNED_ROOT="workspace-root"

# Trees that live inside the workspace but are not workspace services.
IGNORE_DIRS="frnd-orchestration-1-staging"

APPLY=0
FORCE_RELEASE=0
SLUG=""
EXPECTED_FOR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)     APPLY=1 ;;
    --check)     APPLY=0 ;;
    --force-release) FORCE_RELEASE=1 ;;
    --expected)  shift; EXPECTED_FOR="${1:-}" ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    -*)          echo "unknown flag: $1" >&2; exit 2 ;;
    *)           SLUG="$1" ;;
  esac
  shift
done

[ -f "$STATE" ] || { echo "no $STATE at $ROOT — not a workspace root" >&2; exit 2; }

read_state() { python3 - "$@" <<'PY'
import json, sys
slug = sys.argv[1] if len(sys.argv) > 1 else ""
state = json.load(open(".workflow-state.json"))
slug = slug or state.get("active_feature") or ""
feat = (state.get("features") or {}).get(slug)
if not feat:
    print("ERR\tno such feature: %s" % (slug or "<none active>"))
    raise SystemExit(0)
branch = feat.get("branch") or ""
svcs = feat.get("services")
if not svcs:
    svcs = sorted((feat.get("service_prds") or {}).keys())
print("OK\t%s\t%s\t%s" % (slug, branch, ",".join(svcs)))
PY
}

IFS=$'\t' read -r status SLUG BRANCH SCOPE_CSV < <(read_state "$SLUG") || true
if [ "$status" != "OK" ]; then echo "$SLUG" >&2; exit 2; fi
[ -n "$BRANCH" ] || { echo "feature '$SLUG' has no branch recorded — run prd_splitting first" >&2; exit 2; }

roster() {
  if [ -f "$ONBOARD" ]; then
    python3 -c 'import json;print("\n".join(json.load(open(".onboard-state.json")).get("services") or []))'
  else
    printf 'api\nweb\nai-service\ndata-service\norchestration\n'
  fi
}

in_scope() {
  case ",$SCOPE_CSV," in *",$1,"*) return 0 ;; esac
  return 1
}

# Base branch: ask the repo, fall back to AGENTS.md:328-333. api/web develop,
# ai-service/data-service development, orchestration main — a single hardcoded
# "development" would be wrong for three of the five.
base_of() {
  local d="$1" b
  b="$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$b" ]; then echo "${b#origin/}"; return; fi
  case "$d" in
    api|web)                 echo develop ;;
    ai-service|data-service) echo development ;;
    orchestration)           echo main ;;
    *)                       echo main ;;
  esac
}

expected_of() {
  local d="$1"
  if in_scope "$d"; then echo "$BRANCH"; else base_of "$d"; fi
}

# --expected: single-repo lookup for the PreToolUse guard. Silent, one line, no side effects.
if [ -n "$EXPECTED_FOR" ]; then
  case ",$IGNORE_DIRS," in *",$EXPECTED_FOR,"*) exit 0 ;; esac
  [ -d "$EXPECTED_FOR/.git" ] || [ -f "$EXPECTED_FOR/.git" ] || exit 0
  expected_of "$EXPECTED_FOR"
  exit 0
fi

drift=0
blocked=0
printf '%-16s %-46s %-46s %s\n' SERVICE CURRENT EXPECTED STATE
printf '%s\n' "----------------------------------------------------------------------------------------------------------------------"

# workspace-root first, informational only.
if in_scope "$PINNED_ROOT"; then
  cur="$(git branch --show-current)"
  printf '%-16s %-46s %-46s %s\n' "$PINNED_ROOT" "$cur" "$cur" "pinned (never moved)"
fi

PLAN=""
for svc in $(roster); do
  case ",$IGNORE_DIRS," in *",$svc,"*) continue ;; esac
  if [ ! -d "$svc/.git" ] && [ ! -f "$svc/.git" ]; then
    printf '%-16s %-46s %-46s %s\n' "$svc" "-" "-" "MISSING (not cloned)"
    continue
  fi
  cur="$(git -C "$svc" branch --show-current 2>/dev/null || echo '(detached)')"
  exp="$(expected_of "$svc")"
  scope=$(in_scope "$svc" && echo in || echo out)

  if [ "$cur" = "$exp" ]; then
    printf '%-16s %-46s %-46s %s\n' "$svc" "$cur" "$exp" "ok ($scope)"
    continue
  fi

  drift=1
  note="DRIFT ($scope)"

  # Tracked changes block a move. Untracked do not — they survive a checkout, and git
  # refuses on its own if the target branch would overwrite one.
  if [ -n "$(git -C "$svc" status --porcelain --untracked-files=no)" ]; then
    note="BLOCKED — tracked changes, commit or stash yourself"
    blocked=1
  # A release branch is a live claim, not stale drift — in scope or out. Stepping off it
  # does not delete it, but it does walk away from a PR that may be in review, so say so
  # out loud and make it a deliberate act.
  elif [ "$FORCE_RELEASE" = "0" ] && case "$cur" in release/*) true ;; *) false ;; esac; then
    note="BLOCKED — release branch, may be in review (--force-release to step off)"
    blocked=1
  else
    PLAN="$PLAN$svc"$'\t'"$cur"$'\t'"$exp"$'\t'"$scope"$'\n'
  fi
  printf '%-16s %-46s %-46s %s\n' "$svc" "$cur" "$exp" "$note"
done

echo
echo "feature: $SLUG   branch: $BRANCH"
echo "in scope: $SCOPE_CSV"

if [ "$drift" = "0" ]; then
  echo "aligned."
  exit 0
fi

if [ "$APPLY" = "0" ]; then
  echo
  echo "drift found. re-run with --apply to move the movable ones."
  exit 1
fi

if [ -z "$PLAN" ]; then
  echo
  echo "nothing movable — every drifted repo is BLOCKED. Resolve by hand." >&2
  exit 1
fi

echo
echo "applying:"
while IFS=$'\t' read -r svc cur exp scope; do
  [ -n "$svc" ] || continue
  git -C "$svc" fetch origin --quiet
  if git -C "$svc" show-ref --verify --quiet "refs/heads/$exp"; then
    git -C "$svc" checkout --quiet "$exp"
  elif git -C "$svc" show-ref --verify --quiet "refs/remotes/origin/$exp"; then
    git -C "$svc" checkout --quiet -b "$exp" --track "origin/$exp"
  elif [ "$scope" = "in" ]; then
    b="$(base_of "$svc")"
    git -C "$svc" checkout --quiet "$b"
    git -C "$svc" pull --ff-only --quiet origin "$b"
    git -C "$svc" checkout --quiet -b "$exp"
    echo "  $svc: created $exp from $b"
    continue
  else
    echo "  $svc: cannot resolve $exp — skipped" >&2
    continue
  fi
  git -C "$svc" pull --ff-only --quiet origin "$exp" 2>/dev/null || true
  echo "  $svc: $cur -> $exp"
done <<< "$PLAN"

echo
[ "$blocked" = "1" ] && { echo "some repos stayed BLOCKED — see table above." >&2; exit 1; }
echo "aligned."
