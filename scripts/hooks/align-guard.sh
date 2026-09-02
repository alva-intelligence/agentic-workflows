#!/usr/bin/env bash
# align-guard.sh — PreToolUse guard for Edit / Write / NotebookEdit.
#
# Refuses to edit a file inside a service repo that is not on the branch the active feature
# says it should be on. The branch convention in AGENTS.md is prose an agent can skip and
# context compaction can lose; a hook is executed by the harness. Ledger W16b.
#
# TRACKED SOURCE. `.claude/hooks/align-guard.sh` is a copy installed by
# scripts/local-align-wire.sh (or `/align wire`) — edit THIS file, never the copy.
#
# Escape hatch: FRNDOS_ALIGN_OFF=1 disables it for a session.
# Fails open on anything unexpected — a broken guard must not block all editing.
#
# Known gap: Bash-driven writes (sed -i, heredocs) never reach PreToolUse on Edit/Write.
set -uo pipefail
[ "${FRNDOS_ALIGN_OFF:-0}" = "1" ] && exit 0
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ALIGN="$ROOT/scripts/local-align.sh"
[ -x "$ALIGN" ] || exit 0
payload="$(cat)"
file="$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print((d.get("tool_input") or {}).get("file_path") or "")
except Exception:
    print("")' 2>/dev/null)"
[ -n "$file" ] || exit 0
case "$file" in
  "$ROOT"/*) rel="${file#"$ROOT"/}" ;;
  /*)        exit 0 ;;
  *)         rel="$file" ;;
esac
svc="${rel%%/*}"
[ "$svc" != "$rel" ] || exit 0
expected="$("$ALIGN" --expected "$svc" 2>/dev/null)" || exit 0
[ -n "$expected" ] || exit 0
current="$(git -C "$ROOT/$svc" branch --show-current 2>/dev/null)" || exit 0
[ -n "$current" ] || exit 0
[ "$current" = "$expected" ] && exit 0
cat >&2 <<MSG
BLOCKED by align-guard: $svc is on the wrong branch for the active feature.

  file:     $rel
  $svc is on:   $current
  expected:     $expected

Do NOT edit around this. Pick one:
  1. Align the workspace:   ./scripts/local-align.sh --apply
  2. This is separate work:  /workflow start <slug>, then align
  3. Deliberate one-off:     FRNDOS_ALIGN_OFF=1 for this session, and say so out loud

See the whole picture first: ./scripts/local-align.sh
MSG
exit 2
