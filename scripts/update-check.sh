#!/usr/bin/env bash
# update-check.sh — Auto-update agentic-workflows instructions
# Usage: bash .agentic-workflows/scripts/update-check.sh [--bootstrap]
#
# Runs at session start to check for updates to the agentic-workflows
# instruction set. Downloads only changed files by SHA-256 comparison.

set -euo pipefail

# ── Color output ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { printf "${BLUE}[info]${RESET}  %s\n" "$*"; }
ok()      { printf "${GREEN}[ok]${RESET}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[warn]${RESET}  %s\n" "$*"; }
err()     { printf "${RED}[err]${RESET}   %s\n" "$*"; }
header()  { printf "\n${BOLD}${CYAN}── %s ──${RESET}\n" "$*"; }

# ── Constants ────────────────────────────────────────────────────────────────
# TODO: change back to /main before merging to main
REPO_URL_BASE="https://raw.githubusercontent.com/alva-intelligence/agentic-workflows/agentic"
CURL_TIMEOUT=5
BOOTSTRAP=false

# ── Parse flags ──────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --bootstrap) BOOTSTRAP=true ;;
    --help|-h)
      echo "Usage: bash update-check.sh [--bootstrap]"
      echo "  --bootstrap   First-time setup: download all files"
      exit 0
      ;;
    *)
      err "Unknown argument: $arg"
      exit 1
      ;;
  esac
done

# ── Find workspace root ─────────────────────────────────────────────────────
# Walk up from current directory looking for AGENTS.md or .workflow-state.json
find_workspace_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/AGENTS.md" ]] || [[ -f "$dir/.workflow-state.json" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  # If nothing found, use current directory (bootstrap scenario)
  echo "$PWD"
  return 0
}

WORKSPACE_ROOT="$(find_workspace_root)"
CACHE_DIR="$WORKSPACE_ROOT/.agentic-workflows"
VERSION_FILE="$CACHE_DIR/.version"
SCRIPTS_DIR="$CACHE_DIR/scripts"

header "agentic-workflows update check"
info "Workspace: $WORKSPACE_ROOT"
info "Cache dir: $CACHE_DIR"

# ── Ensure cache directory exists ────────────────────────────────────────────
mkdir -p "$CACHE_DIR"

# ── Fetch remote manifest ───────────────────────────────────────────────────
fetch_remote() {
  local url="$1"
  local output
  if output=$(curl -fsSL --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null); then
    echo "$output"
    return 0
  else
    return 1
  fi
}

header "Checking for updates"

REMOTE_MANIFEST=""
if ! REMOTE_MANIFEST=$(fetch_remote "$REPO_URL_BASE/manifest.json"); then
  warn "Could not reach remote (offline or timeout). Skipping update check."
  if [[ "$BOOTSTRAP" == true ]] && [[ ! -f "$VERSION_FILE" ]]; then
    err "Bootstrap requested but cannot reach remote. Please check your network."
    exit 1
  fi
  ok "Using cached version."
  exit 0
fi

# ── Parse remote version ────────────────────────────────────────────────────
# Extract version from JSON without jq (portable)
extract_json_string() {
  local json="$1"
  local key="$2"
  echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

REMOTE_VERSION=$(extract_json_string "$REMOTE_MANIFEST" "version")

if [[ -z "$REMOTE_VERSION" ]]; then
  err "Could not parse remote version from manifest."
  exit 1
fi

info "Remote version: $REMOTE_VERSION"

# ── Read local version ───────────────────────────────────────────────────────
LOCAL_VERSION=""
if [[ -f "$VERSION_FILE" ]]; then
  LOCAL_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
  info "Local version:  $LOCAL_VERSION"
else
  info "Local version:  (none — first run)"
fi

# ── Compare versions ────────────────────────────────────────────────────────
if [[ "$LOCAL_VERSION" == "$REMOTE_VERSION" ]] && [[ "$BOOTSTRAP" == false ]]; then
  ok "Already up-to-date (v$LOCAL_VERSION)."
  exit 0
fi

if [[ "$BOOTSTRAP" == true ]]; then
  header "Bootstrap: downloading all files"
elif [[ -z "$LOCAL_VERSION" ]]; then
  header "First run: downloading all files"
else
  header "Update available: v$LOCAL_VERSION → v$REMOTE_VERSION"
fi

# ── Build file list from remote manifest ─────────────────────────────────────
# Extract file entries: repo_path, sha256, install_to
# We parse the manifest line-by-line for portability (no jq dependency)

declare -a FILE_REPO_PATHS=()
declare -a FILE_SHA256S=()
declare -a FILE_INSTALL_TOS=()

current_repo_path=""
current_sha256=""
current_install_to=""

while IFS= read -r line; do
  # Match a file key like "agents/fragments/session-protocol.md": {
  if [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*:[[:space:]]*\{ ]]; then
    candidate="${BASH_REMATCH[1]}"
    # Skip top-level keys (version, updated, files)
    if [[ "$candidate" != "version" ]] && [[ "$candidate" != "updated" ]] && [[ "$candidate" != "files" ]]; then
      current_repo_path="$candidate"
      current_sha256=""
      current_install_to=""
    fi
  fi

  # Match sha256
  if [[ -n "$current_repo_path" ]] && [[ "$line" =~ \"sha256\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    current_sha256="${BASH_REMATCH[1]}"
  fi

  # Match install_to
  if [[ -n "$current_repo_path" ]] && [[ "$line" =~ \"install_to\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    current_install_to="${BASH_REMATCH[1]}"
  fi

  # When we hit a closing brace and have all three fields, record the entry
  if [[ -n "$current_repo_path" ]] && [[ -n "$current_sha256" ]] && [[ -n "$current_install_to" ]]; then
    FILE_REPO_PATHS+=("$current_repo_path")
    FILE_SHA256S+=("$current_sha256")
    FILE_INSTALL_TOS+=("$current_install_to")
    current_repo_path=""
    current_sha256=""
    current_install_to=""
  fi
done <<< "$REMOTE_MANIFEST"

TOTAL_FILES=${#FILE_REPO_PATHS[@]}
info "Manifest contains $TOTAL_FILES files."

# ── Download changed files ───────────────────────────────────────────────────
UPDATED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
FRAGMENTS_CHANGED=false
declare -a UPDATED_FILES=()

compute_sha256() {
  local file="$1"
  if [[ -f "$file" ]]; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    echo ""
  fi
}

for i in $(seq 0 $(( TOTAL_FILES - 1 ))); do
  repo_path="${FILE_REPO_PATHS[$i]}"
  remote_sha="${FILE_SHA256S[$i]}"
  install_to="${FILE_INSTALL_TOS[$i]}"

  # Resolve install path relative to workspace root
  local_path="$WORKSPACE_ROOT/$install_to"

  # Compute local hash if file exists
  local_sha=""
  if [[ -f "$local_path" ]]; then
    local_sha=$(compute_sha256 "$local_path")
  fi

  # Skip if hashes match (and remote sha is not PLACEHOLDER)
  if [[ "$remote_sha" != "PLACEHOLDER" ]] && [[ "$local_sha" == "$remote_sha" ]]; then
    SKIPPED_COUNT=$(( SKIPPED_COUNT + 1 ))
    continue
  fi

  # If remote sha is PLACEHOLDER, we always download (dev/initial setup)
  # Download the file
  download_url="$REPO_URL_BASE/$repo_path"
  local_dir="$(dirname "$local_path")"
  mkdir -p "$local_dir"

  if file_content=$(fetch_remote "$download_url"); then
    echo "$file_content" > "$local_path"
    UPDATED_COUNT=$(( UPDATED_COUNT + 1 ))
    UPDATED_FILES+=("$install_to")
    printf "  ${GREEN}+${RESET} %s\n" "$install_to"

    # Check if a fragment was updated
    if [[ "$install_to" == *"fragments/"* ]] || [[ "$install_to" == *"AGENTS.md.template"* ]]; then
      FRAGMENTS_CHANGED=true
    fi
  else
    FAILED_COUNT=$(( FAILED_COUNT + 1 ))
    printf "  ${RED}!${RESET} %s (download failed)\n" "$install_to"
  fi
done

# ── Re-generate AGENTS.md if fragments changed ──────────────────────────────
if [[ "$FRAGMENTS_CHANGED" == true ]]; then
  header "Regenerating AGENTS.md"
  GENERATE_SCRIPT="$WORKSPACE_ROOT/.agentic-workflows/scripts/generate-agents.sh"
  if [[ -f "$GENERATE_SCRIPT" ]]; then
    if bash "$GENERATE_SCRIPT"; then
      ok "AGENTS.md regenerated."
    else
      warn "AGENTS.md generation failed (generate-agents.sh returned non-zero)."
    fi
  else
    warn "generate-agents.sh not found at $GENERATE_SCRIPT — skipping AGENTS.md rebuild."
  fi
fi

# ── Create symlinks for tool compatibility ───────────────────────────────────
# .agents/ is the universal path. Symlink tool-specific dirs to it.
header "Setting up tool compatibility symlinks"

# Claude Code: .claude/agents/ → .agents/agents/, .claude/skills/ → .agents/skills/
if [[ -d "$WORKSPACE_ROOT/.agents/agents" ]]; then
  mkdir -p "$WORKSPACE_ROOT/.claude"
  if [[ ! -e "$WORKSPACE_ROOT/.claude/agents" ]]; then
    ln -s "../.agents/agents" "$WORKSPACE_ROOT/.claude/agents"
    ok "Symlinked .claude/agents/ → .agents/agents/"
  fi
fi
if [[ -d "$WORKSPACE_ROOT/.agents/skills" ]]; then
  mkdir -p "$WORKSPACE_ROOT/.claude"
  if [[ ! -e "$WORKSPACE_ROOT/.claude/skills" ]]; then
    ln -s "../.agents/skills" "$WORKSPACE_ROOT/.claude/skills"
    ok "Symlinked .claude/skills/ → .agents/skills/"
  fi
fi

# Cursor: .cursor/agents/ → .agents/agents/, .cursor/skills/ → .agents/skills/
if [[ -d "$WORKSPACE_ROOT/.agents/agents" ]]; then
  mkdir -p "$WORKSPACE_ROOT/.cursor"
  if [[ ! -e "$WORKSPACE_ROOT/.cursor/agents" ]]; then
    ln -s "../.agents/agents" "$WORKSPACE_ROOT/.cursor/agents"
    ok "Symlinked .cursor/agents/ → .agents/agents/"
  fi
fi
if [[ -d "$WORKSPACE_ROOT/.agents/skills" ]]; then
  mkdir -p "$WORKSPACE_ROOT/.cursor"
  if [[ ! -e "$WORKSPACE_ROOT/.cursor/skills" ]]; then
    ln -s "../.agents/skills" "$WORKSPACE_ROOT/.cursor/skills"
    ok "Symlinked .cursor/skills/ → .agents/skills/"
  fi
fi

# OpenCode: .opencode/agents/ → .agents/agents/, .opencode/skills/ → .agents/skills/
if [[ -d "$WORKSPACE_ROOT/.agents/agents" ]]; then
  mkdir -p "$WORKSPACE_ROOT/.opencode"
  if [[ ! -e "$WORKSPACE_ROOT/.opencode/agents" ]]; then
    ln -s "../.agents/agents" "$WORKSPACE_ROOT/.opencode/agents"
    ok "Symlinked .opencode/agents/ → .agents/agents/"
  fi
fi
if [[ -d "$WORKSPACE_ROOT/.agents/skills" ]]; then
  mkdir -p "$WORKSPACE_ROOT/.opencode"
  if [[ ! -e "$WORKSPACE_ROOT/.opencode/skills" ]]; then
    ln -s "../.agents/skills" "$WORKSPACE_ROOT/.opencode/skills"
    ok "Symlinked .opencode/skills/ → .agents/skills/"
  fi
fi

# CLAUDE.md symlink to AGENTS.md (Claude Code reads CLAUDE.md)
if [[ -f "$WORKSPACE_ROOT/AGENTS.md" ]] && [[ ! -e "$WORKSPACE_ROOT/CLAUDE.md" ]]; then
  ln -s "AGENTS.md" "$WORKSPACE_ROOT/CLAUDE.md"
  ok "Symlinked CLAUDE.md → AGENTS.md"
fi

# ── Update local version ────────────────────────────────────────────────────
echo "$REMOTE_VERSION" > "$VERSION_FILE"

# ── Summary ──────────────────────────────────────────────────────────────────
header "Update summary"
ok "Version: v$REMOTE_VERSION"
if [[ $UPDATED_COUNT -gt 0 ]]; then
  info "Updated: $UPDATED_COUNT file(s)"
  for f in "${UPDATED_FILES[@]}"; do
    printf "         %s\n" "$f"
  done
fi
if [[ $SKIPPED_COUNT -gt 0 ]]; then
  info "Unchanged: $SKIPPED_COUNT file(s)"
fi
if [[ $FAILED_COUNT -gt 0 ]]; then
  warn "Failed: $FAILED_COUNT file(s)"
fi
echo ""
ok "Done."

# ── Next steps (shown after bootstrap or first run) ─────────────────────────
if [[ "$BOOTSTRAP" == true ]] || [[ -z "$LOCAL_VERSION" ]]; then
  # Check if this is a fresh workspace (no service dirs)
  has_services=false
  for dir in api web ai-service data-service; do
    if [[ -d "$WORKSPACE_ROOT/$dir" ]]; then
      has_services=true
      break
    fi
  done

  if [[ "$has_services" == false ]]; then
    header "What's next"
    echo ""
    echo "  This is a fresh workspace. Run the onboarding skill to set up"
    echo "  your development environment:"
    echo ""
    echo "     /onboard"
    echo ""
    echo "  This will guide you through:"
    echo "    - Cloning service repositories"
    echo "    - Installing dependencies"
    echo "    - Setting up .env files and database"
    echo "    - Configuring your editor and MCPs"
    echo ""
  else
    header "What's next"
    echo ""
    echo "  1. Start a feature workflow:"
    echo ""
    echo "     /workflow start <feature-slug>"
    echo ""
    echo "  2. Or check available commands:"
    echo ""
    echo "     /workflow status    — show current state"
    echo "     /workflow list      — list all features"
    echo "     /workflow resume    — pick up someone else's feature"
    echo ""
  fi
  printf "  ${BOLD}IMPORTANT:${RESET} Read AGENTS.md now to load the full session protocol.\n"
  echo ""
fi
