# agentic-workflows

Instruction set and orchestration layer for frndOS AI agents. This repository is the single source of truth for agent definitions, workflow phases, skill files, templates, and conventions that Claude Code agents consume when working inside the frnd workspace.

## How it works

Each frnd workspace (e.g. `frnd-app`) installs a local copy of the files from this repo into `.agentic-workflows/` and `.claude/`. A lightweight update mechanism keeps those copies in sync:

1. **You edit files** in this repo (agents, skills, fragments, templates, workflow configs).
2. **Push to `main`**. The `update-manifest` GitHub Action runs automatically.
3. **The Action** computes SHA-256 hashes for every distributable file, bumps the patch version in `VERSION`, and commits the updated `manifest.json` back to the repo.
4. **In the workspace**, `scripts/update-check.sh` compares local hashes against the manifest. If any file is outdated, it pulls the new version.
5. **`scripts/generate-agents.sh`** assembles the final `AGENTS.md` from fragments and the template, so agents always operate with the latest conventions.

The commit message from the Action contains `[manifest]`, which causes the Action to skip itself on the next push -- preventing infinite loops.

## Repository structure

```
agentic-workflows/
  agents/
    fragments/          # Markdown fragments assembled into AGENTS.md
    tools/
      claude-code/      # Agent definition files for Claude Code
    AGENTS.md.template  # Template that includes fragment references
  scripts/
    update-check.sh     # Pulls updates from this repo into a workspace
    generate-agents.sh  # Assembles AGENTS.md from fragments + template
  skills/
    workflow-manager/   # /workflow slash command skill
    prd-creator/        # /prd slash command skill
    prd-splitter/       # /prd-split slash command skill
    wireframe-builder/  # /wireframe slash command skill
  templates/
    prd/                # PRD document templates
    tracks/             # Track/task breakdown templates
  workflow/
    phases.json         # Workflow phase definitions
    gates.json          # Quality gate definitions
    state-schema.json   # Schema for .workflow-state.json
  wireframe-scaffold/
    layout.tsx          # Scaffold for (dashboard)/workflows/layout.tsx
    page.tsx            # Scaffold for (dashboard)/workflows/page.tsx
  manifest.json         # File registry with SHA-256 hashes and install paths
  VERSION               # Current version (semver, patch auto-bumped)
  flake.nix             # Nix flake for reproducible dev environments
  .github/
    workflows/
      update-manifest.yml  # GitHub Action that updates manifest on push
```

## Making changes

1. Clone this repo (or edit in the GitHub UI).
2. Edit the relevant file -- agent definitions, fragments, skills, templates, etc.
3. Push to `main`.
4. The GitHub Action bumps `VERSION`, recomputes all SHA-256 hashes, and commits the updated `manifest.json`.
5. Next time an agent runs `update-check.sh` in a workspace, it picks up the new files.

If you add a **new file** that should be distributed, you must also add an entry to `manifest.json` under the `files` key with:
- The file path (relative to repo root) as the key
- `sha256`: set to `"PLACEHOLDER"` (the Action will fill it in)
- `install_to`: the destination path relative to the workspace root
- `type`: one of `fragment`, `template`, `script`, `skill`, `agent`, `workflow`, `config`

## Manual testing

To test changes locally before pushing:

```bash
# From the frnd workspace root:

# Check for updates against the remote manifest
bash .agentic-workflows/scripts/update-check.sh

# Regenerate AGENTS.md from current fragments
bash .agentic-workflows/scripts/generate-agents.sh
```

You can also run the hash computation locally to verify:

```bash
# From the agentic-workflows repo root:
for f in $(jq -r '.files | keys[]' manifest.json); do
  echo "$f: $(shasum -a 256 "$f" | awk '{print $1}')"
done
```

## Version scheme

Versions follow `MAJOR.MINOR.PATCH`:
- **MAJOR** -- breaking changes to agent protocol or workflow state schema
- **MINOR** -- new agents, skills, or workflow phases
- **PATCH** -- auto-bumped on every push to `main` by the GitHub Action

The current version lives in the `VERSION` file and is mirrored in `manifest.json`.

## Key conventions

- Commit messages containing `[skip ci]` or `[manifest]` will not trigger the update Action.
- All distributable files must be registered in `manifest.json` to be synced.
- Wireframe scaffolds in `wireframe-scaffold/` are copied to workspaces during the `/wireframe create` onboarding step, not via the normal manifest sync.
