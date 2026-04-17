#!/usr/bin/env bash
# lark-sync-bootstrap.sh
# Creates the shared Lark tasklist, sections, and custom fields from
# workflow/lark-template.json. Writes the runtime config to .lark-sync.json
# in the current working directory. Idempotent: if a matching tasklist exists
# (same name, owned by the user), prompts to reuse or create new.
#
# Requires: lark-cli authenticated with task:* + task:custom_field:* scopes.
# Reads: workflow/lark-template.json (from either cwd or .agentic-workflows/)

set -euo pipefail

TEMPLATE=""
for p in "workflow/lark-template.json" ".agentic-workflows/workflow/lark-template.json"; do
  if [[ -f "$p" ]]; then TEMPLATE="$p"; break; fi
done
if [[ -z "$TEMPLATE" ]]; then
  echo "error: workflow/lark-template.json not found" >&2
  exit 1
fi

NAME="${1:-$(jq -r '.tasklist_name' "$TEMPLATE")}"

# Pre-flight
if ! command -v lark-cli &>/dev/null; then
  echo "error: lark-cli not installed. Run: npm install -g @larksuite/cli" >&2
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "error: jq required" >&2
  exit 1
fi

REQUIRED_SCOPES=(
  # Tasks
  task:task:read task:task:write
  task:tasklist:read task:tasklist:write
  task:section:read task:section:write
  task:comment:read task:comment:write
  task:custom_field:read task:custom_field:write
  task:attachment:read task:attachment:write
  # Docs / Docx
  docs:document.content:read
  docx:document:readonly
  # Base (Bitable)
  bitable:app bitable:app:readonly
  # Drive (full)
  drive:drive drive:file drive:file:download drive:export:readonly
  # Wiki (all)
  wiki:wiki wiki:wiki:readonly
  wiki:node:read wiki:node:retrieve wiki:node:create wiki:node:copy wiki:node:move
  wiki:space:read wiki:space:retrieve wiki:space:write_only
  wiki:member:create wiki:member:retrieve wiki:member:update
  # Token refresh
  offline_access
)
LOGIN_SCOPE_STRING="${REQUIRED_SCOPES[*]}"

scopes=$(lark-cli auth status 2>&1 | jq -r '.scope // ""' | tr ' ' '\n')
for s in "${REQUIRED_SCOPES[@]}"; do
  if ! grep -qx "$s" <<<"$scopes"; then
    echo "error: missing scope: $s" >&2
    echo "  Run: lark-cli auth login --scope '$LOGIN_SCOPE_STRING'" >&2
    exit 1
  fi
done

echo "→ Creating tasklist: $NAME"
create_resp=$(lark-cli task tasklists create --data "$(jq -nc --arg n "$NAME" '{name:$n}')" 2>&1)
TL=$(echo "$create_resp" | jq -r '.data.tasklist.guid // empty')
if [[ -z "$TL" ]]; then
  echo "error: failed to create tasklist" >&2
  echo "$create_resp" >&2
  exit 1
fi
echo "  tasklist_guid: $TL"

# Fetch the default section (Lark auto-creates one). Rename + move it to be the "default phase" section.
default_name=$(jq -r '.sections.default' "$TEMPLATE")
default_phase_key=$(jq -r --arg d "$default_name" '.sections.ordered[] | select(.name == $d) | .phase_key' "$TEMPLATE")

default_sec_guid=$(lark-cli api GET /open-apis/task/v2/sections --params "{\"resource_type\":\"tasklist\",\"resource_id\":\"$TL\"}" 2>&1 | jq -r '.data.items[] | select(.is_default==true) | .guid')

echo "→ Renaming default section to: $default_name"
lark-cli api PATCH "/open-apis/task/v2/sections/$default_sec_guid" --data "$(jq -nc --arg n "$default_name" '{section:{name:$n},update_fields:["name"]}')" >/dev/null

declare -A SECTION_GUIDS
SECTION_GUIDS["$default_name"]="$default_sec_guid"

# Create remaining sections in order, skipping the default one (already renamed).
prev_guid="$default_sec_guid"
while read -r row; do
  name=$(jq -r '.name' <<<"$row")
  if [[ "$name" == "$default_name" ]]; then
    continue
  fi
  body=$(jq -nc --arg tl "$TL" --arg n "$name" --arg prev "$prev_guid" '{resource_type:"tasklist",resource_id:$tl,name:$n,insert_after:$prev}')
  resp=$(lark-cli api POST /open-apis/task/v2/sections --data "$body" 2>&1)
  guid=$(jq -r '.data.section.guid // empty' <<<"$resp")
  if [[ -z "$guid" ]]; then
    echo "error creating section $name:" >&2
    echo "$resp" >&2
    exit 1
  fi
  echo "  section: $name → $guid"
  SECTION_GUIDS["$name"]="$guid"
  prev_guid="$guid"
done < <(jq -c '.sections.ordered[]' "$TEMPLATE")

# Create custom fields.
declare -A FIELD_META
while read -r row; do
  name=$(jq -r '.name' <<<"$row")
  type=$(jq -r '.type' <<<"$row")
  body_args=(--arg tl "$TL" --arg n "$name" --arg t "$type")
  body_filter='{resource_type:"tasklist",resource_id:$tl,name:$n,type:$t}'
  case "$type" in
    single_select)
      options_json=$(jq -c '[.options[] | {name: .}]' <<<"$row")
      body_args+=(--argjson opts "$options_json")
      body_filter="$body_filter + {single_select_setting:{options:\$opts}}"
      ;;
    multi_select)
      options_json=$(jq -c '[.options[] | {name: .}]' <<<"$row")
      body_args+=(--argjson opts "$options_json")
      body_filter="$body_filter + {multi_select_setting:{options:\$opts}}"
      ;;
    datetime)
      fmt=$(jq -r '.datetime_format // "yyyy-mm-dd"' <<<"$row")
      body_args+=(--arg fmt "$fmt")
      body_filter="$body_filter + {datetime_setting:{format:\$fmt}}"
      ;;
  esac
  body=$(jq -nc "${body_args[@]}" "$body_filter")
  resp=$(lark-cli api POST /open-apis/task/v2/custom_fields --data "$body" 2>&1)
  guid=$(jq -r '.data.custom_field.guid // empty' <<<"$resp")
  if [[ -z "$guid" ]]; then
    echo "error creating field $name:" >&2
    echo "$resp" >&2
    exit 1
  fi
  echo "  field: $name → $guid"
  FIELD_META["$name"]="$guid"
done < <(jq -c '.custom_fields[]' "$TEMPLATE")

# Build the runtime config (re-fetch to pick up auto-generated option GUIDs).
echo "→ Building .lark-sync.json"
sections=$(lark-cli api GET /open-apis/task/v2/sections --params "{\"resource_type\":\"tasklist\",\"resource_id\":\"$TL\"}" | jq '.data.items | map({(.name): {guid, is_default: (.is_default // false)}}) | add')
fields=$(lark-cli api GET /open-apis/task/v2/custom_fields --params "{\"resource_type\":\"tasklist\",\"resource_id\":\"$TL\"}" | jq '.data.items | map({(.name): {guid, type, options: ((.single_select_setting.options // .multi_select_setting.options // []) | map({(.name): .guid}) | add // {})}}) | add')

jq -n --arg tl "$TL" --arg name "$NAME" --argjson s "$sections" --argjson f "$fields" '{
  tasklist_guid: $tl,
  tasklist_name: $name,
  created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
  sections: $s,
  fields: $f,
  feature_task_guids: {}
}' > .lark-sync.json

# Ensure .lark-sync.json is gitignored (workspace root is usually not a git repo,
# but service repos and .agentic-workflows state may be — add it defensively).
for gi in .gitignore .agentic-workflows/.gitignore; do
  if [[ -f "$gi" ]] && ! grep -q "^\.lark-sync\.json$" "$gi" 2>/dev/null; then
    echo ".lark-sync.json" >> "$gi"
  fi
done

echo ""
echo "✓ Done. Tasklist GUID: $TL"
echo "  Share this GUID with teammates — they run: /lark-sync link $TL"
