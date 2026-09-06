#!/usr/bin/env python3
"""Fail when a distributed file is missing from `manifest.json`.

WHY THIS EXISTS (local-pipeline-e2e FR-39)
------------------------------------------
Onboarding installs exactly the files `manifest.json` declares. A file that
lives under a distributed directory but is not in the manifest is therefore
invisible to every onboarded workspace, and nothing today notices.

That is not hypothetical. `scripts/local-seed-raw.py` and
`scripts/local-run-pipeline.sh` sat unmanifested for weeks while the PRD
assigned fifteen requirements to them and `skills/onboard/SKILL.md` instructed
every developer to run them. They arrived that way through an ordinary
housekeeping commit (`0505be8`).

`update-manifest.yml` cannot catch it: it iterates `jq -r '.files | keys[]'`,
so it recomputes hashes for files ALREADY declared and has no way to discover
one that is not. It closes the loop for maintenance and leaves it open for
addition. This check closes the addition half.

The reverse direction is checked too — a manifest entry whose file has been
deleted installs nothing and fails a fresh bootstrap.

EXCLUSIONS
----------
Add a path or a `fnmatch` glob to `EXCLUSIONS` below WITH A REASON. An
exclusion is a deliberate statement that a file is repo-internal and must not
be distributed; a bare path with no reason is indistinguishable from an
oversight, which is the failure mode this check exists to prevent.
"""

from __future__ import annotations

import fnmatch
import json
import subprocess
import sys
from pathlib import Path

# Directories whose contents are installed into a workspace by the manifest.
DISTRIBUTED_DIRS = ("scripts/", "skills/", "agents/", "templates/", "workflow/")

# path-or-glob -> why it is not distributed. Both parts are required.
EXCLUSIONS: dict[str, str] = {
    "scripts/check-manifest-coverage.py": (
        "This check itself. It runs in CI against this repo's own tree and has "
        "no meaning inside an onboarded workspace, which has no manifest.json "
        "to check."
    ),
}

def tracked_files() -> set[str]:
    out = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout.split("\n")
    return {f for f in out if f}

def excluded(path: str) -> bool:
    return any(
        path == pattern or fnmatch.fnmatch(path, pattern) for pattern in EXCLUSIONS
    )

def main() -> int:
    root = Path(__file__).resolve().parent.parent
    manifest = json.loads((root / "manifest.json").read_text())
    declared = set(manifest.get("files", {}))

    under_dirs = {
        f for f in tracked_files() if f.startswith(DISTRIBUTED_DIRS)
    }

    missing = sorted(f for f in under_dirs - declared if not excluded(f))
    orphaned = sorted(declared - under_dirs)

    if missing:
        print(
            "Files under a distributed directory are missing from manifest.json.\n"
            "An onboarded workspace will NOT receive them, and nothing else will\n"
            "tell you so — update-manifest.yml only rehashes files already declared.\n",
            file=sys.stderr,
        )
        for f in missing:
            print(f"  missing from manifest: {f}", file=sys.stderr)
        print(
            "\nFix by adding each to manifest.json with its install_to path, or by\n"
            "adding it to EXCLUSIONS in this script WITH A REASON.",
            file=sys.stderr,
        )

    if orphaned:
        print(
            "\nmanifest.json declares files that are not tracked under a\n"
            "distributed directory. A fresh bootstrap will fail to install them.\n",
            file=sys.stderr,
        )
        for f in orphaned:
            print(f"  declared but not tracked: {f}", file=sys.stderr)

    if missing or orphaned:
        return 1

    print(
        f"manifest coverage OK — {len(declared)} declared, "
        f"{len(under_dirs)} tracked under {', '.join(DISTRIBUTED_DIRS)}"
        + (f", {len(EXCLUSIONS)} excluded" if EXCLUSIONS else "")
    )
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
