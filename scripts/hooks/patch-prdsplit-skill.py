#!/usr/bin/env python3
"""Patch the installed /prd-split skill so it records `services` and aligns the workspace.

Called by scripts/local-align-wire.sh against .agents/skills/prd-split/SKILL.md. Idempotent.
`services` is what scripts/local-align.sh and the align-guard hook enforce — a feature that
leaves it null has no scope, and the guard is off for it. Ledger W17.
"""
import sys

OLD = "9. Update `.workflow-state.json` `service_prds` with paths."
NEW = """9. Update `.workflow-state.json` `service_prds` with paths, and set **`services`** to the same
   keys as workspace *directory* names (`orchestration`, not `frnd-orchestration`). `services`
   is what `scripts/local-align.sh` and the `align-guard` hook enforce — leaving it `null`
   turns the guard off for this feature.

9b. Run `/align <slug> apply` so every in-scope service is on the new feature branch and every
   uninvolved service is parked. Report the table.

9c. Then, as before: Update `.workflow-state.json` `service_prds` with paths."""


def main(path: str) -> int:
    s = open(path).read()
    if "local-align" in s:
        return 0
    if OLD in s:
        s = s.replace(OLD, NEW, 1)
        open(path, "w").write(s)
    else:
        print("warn: prd-split step 9 anchor not found — not patched", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
