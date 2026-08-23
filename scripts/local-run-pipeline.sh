#!/usr/bin/env bash
# local-run-pipeline.sh — run raw → staging → marts on the LOCAL stack.
#
# Companion to `local-seed-raw.py`, which builds the raw layer this reads.
# Together they make `frnd-orchestration` runnable without Fivetran, without
# the shared Prefect server, and without touching ClickHouse Cloud.
#
#   scripts/local-seed-raw.py --brand <brand> --drop     # 1. raw
#   scripts/local-run-pipeline.sh <workspace> <brand>    # 2. staging + marts
#
# SAFETY — three things keep this local, and all three are checked below:
#   * PREFECT_PROFILE=local, so runs land on 127.0.0.1:4200, never
#     prefect.frndos.com (which serves staging AND production at once).
#     `prefect profile use` is deliberately NOT called: it rewrites
#     ~/.prefect/profiles.toml globally and would silently retarget every later
#     command, including yours.
#   * the `clickhouse-host` Secret block must read `localhost`.
#   * no callback_url is passed, so the flow's state hook returns before it can
#     POST anything anywhere.
set -euo pipefail

WORKSPACE="${1:-}"
BRAND="${2:-}"
PLATFORMS="${3:-instagram_business,facebook_pages,tiktok,youtube}"

if [[ -z "$WORKSPACE" || -z "$BRAND" ]]; then
  echo "usage: $0 <workspace_id> <brand_id> [platform,platform,...]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH="$ROOT/orchestration"
PY="$ORCH/.venv/bin/python"
export PREFECT_PROFILE=local

[[ -x "$PY" ]] || { echo "missing venv: $PY" >&2; exit 1; }

# Guard: refuse to run if the blocks point anywhere but localhost. Without this
# the only thing standing between a local test run and a write to Cloud staging
# is which block someone edited last.
host=$(cd "$ORCH" && PYTHONPATH=. "$PY" -c \
  "from prefect.blocks.system import Secret; print(Secret.load('clickhouse-host').get())" 2>/dev/null | tail -1)
if [[ "$host" != "localhost" && "$host" != "127.0.0.1" ]]; then
  echo "REFUSING TO RUN — clickhouse-host block is '$host', not localhost." >&2
  echo "Point it at localhost before running the pipeline locally." >&2
  exit 1
fi
echo "clickhouse-host = $host  ·  prefect = ${PREFECT_API_URL:-127.0.0.1:4200}"
echo

IFS=',' read -ra PLATS <<< "$PLATFORMS"
for p in "${PLATS[@]}"; do
  printf '%-22s ' "$p"
  if (cd "$ORCH" && PYTHONPATH=. "$PY" -c "
from flows.platform_pipeline_flow import platform_pipeline_flow
platform_pipeline_flow(workspace_id='$WORKSPACE', brand_id='$BRAND', platform='$p')
" > "/tmp/local-pipeline-$p.log" 2>&1); then
    grep -oE 'social_content_performance: [0-9]+ rows' "/tmp/local-pipeline-$p.log" | tail -1
  else
    echo "FAILED — see /tmp/local-pipeline-$p.log"
  fi
done

echo
echo "mart state for brand $BRAND:"
(cd "$ORCH" && PYTHONPATH=. "$PY" -c "
import clickhouse_connect
ch = clickhouse_connect.get_client(host='localhost', port=8123, username='default', password='', secure=False)
q = '''
SELECT channel,
       count()                                  AS posts,
       countIf(new_follows IS NOT NULL)         AS follows,
       countIf(avg_watch_time_ms IS NOT NULL)   AS watch,
       countIf(skip_rate_3s IS NOT NULL)        AS skip,
       countIf(retained_views_3s > video_views) AS impossible
FROM frnd_agg_marts.social_content_performance FINAL
WHERE brand_id = '$BRAND'
GROUP BY channel ORDER BY posts DESC'''
r = ch.query(q)
print('  ' + ' | '.join(f'{c:10}' for c in r.column_names))
for row in r.result_rows:
    print('  ' + ' | '.join(f'{str(x):10}' for x in row))
")
echo
echo "Expected: Instagram carries follows/watch/skip; every other channel reads 0"
echo "(= NULL = 'this platform does not report it'), and impossible is 0 everywhere."
