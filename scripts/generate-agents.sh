#!/usr/bin/env bash
# generate-agents.sh — Assemble AGENTS.md from template + fragments
# Usage: bash .agentic-workflows/scripts/generate-agents.sh
#
# Reads AGENTS.md.template, replaces {{FRAGMENT:filename}} markers with
# the content of the corresponding fragment files, substitutes {{VERSION}}
# and {{DATE}}, then writes the assembled AGENTS.md to the workspace root.

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
err()     { printf "${RED}[err]${RESET}   %s\n" "$*" >&2; }
header()  { printf "\n${BOLD}${CYAN}── %s ──${RESET}\n" "$*"; }

# ── Find workspace root ─────────────────────────────────────────────────────
find_workspace_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/AGENTS.md" ]] || [[ -f "$dir/.workflow-state.json" ]] || [[ -d "$dir/.agentic-workflows" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "$PWD"
  return 0
}

WORKSPACE_ROOT="$(find_workspace_root)"
CACHE_DIR="$WORKSPACE_ROOT/.agentic-workflows"

header "Generating AGENTS.md"
info "Workspace: $WORKSPACE_ROOT"

# ── Locate template ─────────────────────────────────────────────────────────
TEMPLATE_FILE=""
FRAGMENTS_DIR=""

# Check workspace cache first (installed location)
if [[ -f "$CACHE_DIR/AGENTS.md.template" ]]; then
  TEMPLATE_FILE="$CACHE_DIR/AGENTS.md.template"
  FRAGMENTS_DIR="$CACHE_DIR/fragments"
# Check repo source location (if running from within the repo)
elif [[ -f "$WORKSPACE_ROOT/agents/AGENTS.md.template" ]]; then
  TEMPLATE_FILE="$WORKSPACE_ROOT/agents/AGENTS.md.template"
  FRAGMENTS_DIR="$WORKSPACE_ROOT/agents/fragments"
else
  err "Cannot find AGENTS.md.template in either:"
  err "  $CACHE_DIR/AGENTS.md.template"
  err "  $WORKSPACE_ROOT/agents/AGENTS.md.template"
  exit 1
fi

info "Template: $TEMPLATE_FILE"
info "Fragments: $FRAGMENTS_DIR"

# ── Read version ─────────────────────────────────────────────────────────────
VERSION="unknown"
if [[ -f "$CACHE_DIR/.version" ]]; then
  VERSION=$(cat "$CACHE_DIR/.version" | tr -d '[:space:]')
elif [[ -f "$CACHE_DIR/VERSION" ]]; then
  VERSION=$(cat "$CACHE_DIR/VERSION" | tr -d '[:space:]')
elif [[ -f "$WORKSPACE_ROOT/VERSION" ]]; then
  VERSION=$(cat "$WORKSPACE_ROOT/VERSION" | tr -d '[:space:]')
fi

CURRENT_DATE=$(date "+%Y-%m-%d")

info "Version: $VERSION"
info "Date: $CURRENT_DATE"

# ── Process template ─────────────────────────────────────────────────────────
OUTPUT_FILE="$WORKSPACE_ROOT/AGENTS.md"
FRAGMENT_COUNT=0
MISSING_FRAGMENTS=0

# Read template into variable
TEMPLATE_CONTENT=$(cat "$TEMPLATE_FILE")

# Replace {{VERSION}}
TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{VERSION\}\}/$VERSION}"

# Replace {{DATE}}
TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{DATE\}\}/$CURRENT_DATE}"

# Process {{FRAGMENT:filename}} markers
# We read line by line to handle fragment replacement properly
OUTPUT_CONTENT=""
while IFS= read -r line || [[ -n "$line" ]]; do
  # Check if line contains a fragment marker
  if [[ "$line" =~ \{\{FRAGMENT:([^}]+)\}\} ]]; then
    fragment_name="${BASH_REMATCH[1]}"

    # Try to find the fragment file
    fragment_path=""
    if [[ -f "$FRAGMENTS_DIR/$fragment_name" ]]; then
      fragment_path="$FRAGMENTS_DIR/$fragment_name"
    elif [[ -f "$FRAGMENTS_DIR/${fragment_name}.md" ]]; then
      fragment_path="$FRAGMENTS_DIR/${fragment_name}.md"
    fi

    if [[ -n "$fragment_path" ]] && [[ -f "$fragment_path" ]]; then
      # Replace the marker with fragment content
      # Get the text before and after the marker on this line
      local_prefix="${line%%\{\{FRAGMENT:*}"
      local_suffix="${line#*\}\}}"

      if [[ -n "$local_prefix" ]] || [[ -n "$local_suffix" ]]; then
        # There's text around the marker; put prefix, content, suffix
        OUTPUT_CONTENT+="${local_prefix}"$'\n'
        OUTPUT_CONTENT+="$(cat "$fragment_path")"$'\n'
        if [[ -n "$local_suffix" ]]; then
          OUTPUT_CONTENT+="${local_suffix}"$'\n'
        fi
      else
        # Marker is the entire line — replace with fragment content
        OUTPUT_CONTENT+="$(cat "$fragment_path")"$'\n'
      fi

      FRAGMENT_COUNT=$(( FRAGMENT_COUNT + 1 ))
      printf "  ${GREEN}+${RESET} %s → %s\n" "$fragment_name" "$fragment_path"
    else
      # Fragment not found — leave marker and warn
      OUTPUT_CONTENT+="$line"$'\n'
      MISSING_FRAGMENTS=$(( MISSING_FRAGMENTS + 1 ))
      printf "  ${RED}!${RESET} %s (not found)\n" "$fragment_name"
    fi
  else
    OUTPUT_CONTENT+="$line"$'\n'
  fi
done <<< "$TEMPLATE_CONTENT"

# ── Write output ─────────────────────────────────────────────────────────────
# Remove trailing newline duplication
printf "%s" "$OUTPUT_CONTENT" > "$OUTPUT_FILE"

# ── Summary ──────────────────────────────────────────────────────────────────
header "Generation summary"
ok "Output: $OUTPUT_FILE"
info "Fragments inserted: $FRAGMENT_COUNT"
if [[ $MISSING_FRAGMENTS -gt 0 ]]; then
  warn "Missing fragments: $MISSING_FRAGMENTS"
fi

# Report file size
if command -v wc &>/dev/null; then
  LINE_COUNT=$(wc -l < "$OUTPUT_FILE" | tr -d '[:space:]')
  BYTE_COUNT=$(wc -c < "$OUTPUT_FILE" | tr -d '[:space:]')
  info "Output size: $LINE_COUNT lines, $BYTE_COUNT bytes"
fi

echo ""
ok "Done."
