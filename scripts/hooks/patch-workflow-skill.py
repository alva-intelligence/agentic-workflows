#!/usr/bin/env python3
"""Patch the installed /workflow skill so `switch` aligns the workspace instead of advising.

Called by scripts/local-align-wire.sh against .agents/skills/workflow/SKILL.md — the gitignored
install copy. Idempotent and marker-guarded by the caller. Patching (not copying our tracked
copy over it) is deliberate: `workflow` exists upstream, and a copy would silently revert any
upstream update. Ledger W17.
"""
import sys

ARROW = "→"

OLD_SWITCH = (
    '6. If on a different git branch, inform user: "Feature `<slug>` is on branch '
    '`{branch}`. Switch with: `git checkout {branch}`"'
)
NEW_SWITCH = """6. **Align the whole workspace — do not merely advise.** Run `/align <slug>` (or
   `./scripts/local-align.sh <slug>`) to show the table, then `--apply` to move every repo:
   in-scope services (`features[<slug>].services`) go to `features[<slug>].branch`; every
   other service parks on its own default branch. `workspace-root` is pinned and never moved.
   The script refuses on tracked-file changes and on `release/*` branches (`--force-release`
   to override) — report what it refused, never work around it."""

OLD_STATUS = "   - PRs: list `{pr_urls}` entries (service " + ARROW + ' URL) or "not submitted"'
NEW_STATUS = OLD_STATUS + """
3. **Run `/align` (read-only) and show its table.** It exits 1 on drift."""

OLD_ENTRY = '     "branch": null,\n     "service_prds": {},'
NEW_ENTRY = '     "branch": null,\n     "services": [],\n     "service_prds": {},'


def main(path: str) -> int:
    s = open(path).read()
    if "local-align" in s:
        return 0
    for old, new in ((OLD_SWITCH, NEW_SWITCH), (OLD_STATUS, NEW_STATUS), (OLD_ENTRY, NEW_ENTRY)):
        if old in s:
            s = s.replace(old, new, 1)
        else:
            print(f"warn: anchor not found, skipped: {old[:60]}...", file=sys.stderr)
    open(path, "w").write(s)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
