#!/usr/bin/env bash
# run-all.sh — Start all frndOS services concurrently
# Usage: ./run-all.sh [--stop] [--status] [--check]
#
# Requires the toolchain from /onboard Step 2 to be on PATH.
# Services: API (9191), Frontend (3000), AI Service (8000), Data Service (9999),
#           Hocuspocus (1234)
#
# Hocuspocus starts only when hocuspocus/ and hocuspocus/.env both exist. It stores Yjs
# updates in the API's Postgres and needs the API running for auth, so it starts last.
#
# NOT started here: Data Pipeline has no long-running server (flows run on a Prefect
# worker) and is absent by design. Postgres 5432, Redis 6379, ClickHouse 8123 and Prefect 4200
# are SHARED_PORTS: reported by --check and --status, and NEVER killed by --stop or
# --kill-ports. /onboard tells the developer to leave them running, so killing them here
# would break the estate the same run just set up. Enforced by the two arrays below --
# every kill loop iterates OWNED_PORTS only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$SCRIPT_DIR/.pids"
LOG_DIR="$SCRIPT_DIR/.logs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "$PID_DIR" "$LOG_DIR"

log_info()  { echo -e "${BLUE}[info]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[ok]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[warn]${NC}  $1"; }
log_err()   { echo -e "${RED}[error]${NC} $1"; }

save_pid() { echo "$2" > "$PID_DIR/$1.pid"; }

read_pid() {
  local pid_file="$PID_DIR/$1.pid"
  if [[ -f "$pid_file" ]]; then
    cat "$pid_file"
  fi
}

is_running() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

# ── Ports ────────────────────────────────────────────────────────────────────
# OWNED: started by this script, so this script may stop them.
# SHARED: started by the developer per /onboard 7.4.2 and 7.5.2 and left running on
#         purpose. Observed, never killed. Do not merge these two lists.
OWNED_PORTS=(9191 3000 8000 9999 1025 8025)
SHARED_PORTS=(5432 6379 8123 4200)
CHECK_PORTS=("${OWNED_PORTS[@]}")

port_pid() { lsof -ti :"$1" 2>/dev/null || true; }
port_cmd() { ps -p "$1" -o comm= 2>/dev/null || echo "unknown"; }

HOCUSPOCUS_PORT=""
if [[ -d "$SCRIPT_DIR/hocuspocus" && -f "$SCRIPT_DIR/hocuspocus/.env" ]]; then
  HOCUSPOCUS_PORT=$(node -e '
    try {
      process.loadEnvFile(process.argv[1]);
      const port = Number(process.env.PORT ?? 1234);
      if (!Number.isInteger(port) || port < 1 || port > 65535) process.exit(1);
      process.stdout.write(String(port));
    } catch { process.exit(1); }
  ' "$SCRIPT_DIR/hocuspocus/.env" 2>/dev/null) || true
  for reserved_port in "${OWNED_PORTS[@]}" "${SHARED_PORTS[@]}"; do
    [[ "$HOCUSPOCUS_PORT" != "$reserved_port" ]] || HOCUSPOCUS_PORT=""
  done
  [[ -z "$HOCUSPOCUS_PORT" ]] || CHECK_PORTS+=("$HOCUSPOCUS_PORT")
fi

# ── Port conflict check ──────────────────────────────────────────────────────
check_ports() {
  local conflicts=0
  for port in "${CHECK_PORTS[@]}"; do
    local pid
    pid=$(port_pid "$port")
    if [[ -n "$pid" ]]; then
      log_warn "Port $port in use by PID $pid ($(port_cmd "$pid"))"
      conflicts=$((conflicts + 1))
    fi
  done
  # Shared ports are reported for orientation only. In use is the EXPECTED state for a
  # data developer and must never count as a conflict or trigger a kill suggestion.
  for port in "${SHARED_PORTS[@]}"; do
    local pid
    pid=$(port_pid "$port")
    if [[ -n "$pid" ]]; then
      log_ok "Port $port in use by PID $pid ($(port_cmd "$pid")) — shared, left alone"
    fi
  done
  if [[ $conflicts -gt 0 ]]; then
    echo ""
    log_warn "$conflicts port conflict(s). Stop existing processes; --kill-ports only covers ${OWNED_PORTS[*]}."
    log_warn "Hocuspocus uses its tracked process group, never port-based kills. Shared ports ${SHARED_PORTS[*]} are left alone."
    return 1
  fi
  return 0
}

# ── Kill conflicting ports ───────────────────────────────────────────────────
kill_ports() {
  for port in "${OWNED_PORTS[@]}"; do
    local pid
    pid=$(port_pid "$port")
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null && log_ok "Killed PID $pid on port $port" || log_warn "Failed to kill PID $pid"
    fi
  done
}

# ── Stop ─────────────────────────────────────────────────────────────────────
stop_all() {
  echo -e "\n${BOLD}Stopping all services...${NC}\n"

  local pid
  pid=$(read_pid hocuspocus)
  if [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 && -f "$PID_DIR/hocuspocus.started" ]] &&
     is_running "$pid" &&
     [[ "$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)" == "$(cat "$PID_DIR/hocuspocus.started")" ]] &&
     [[ "$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]')" == "$pid" ]]; then
    kill -- "-$pid" 2>/dev/null && log_ok "Stopped hocuspocus process group (PID $pid)" || log_warn "Failed to stop hocuspocus"
  elif [[ -n "$pid" ]]; then
    log_warn "Hocuspocus PID could not be verified; no process killed"
  fi
  rm -f "$PID_DIR/hocuspocus.pid" "$PID_DIR/hocuspocus.started"

  # 1. Stop tracked PIDs
  for name in api api-queue web ai-service data-service mailhog; do
    local pid
    pid=$(read_pid "$name")
    if is_running "$pid"; then
      kill "$pid" 2>/dev/null && log_ok "Stopped $name (PID $pid)" || log_warn "Failed to stop $name"
      rm -f "$PID_DIR/$name.pid"
    fi
  done

  # 2. Kill anything still on OUR ports (catches orphaned processes).
  #    OWNED_PORTS only -- 8123/4200 belong to the developer's local ClickHouse and
  #    Prefect, which /onboard asked them to leave running.
  for port in "${OWNED_PORTS[@]}"; do
    local pid
    pid=$(port_pid "$port")
    if [[ -n "$pid" ]]; then
      kill -9 "$pid" 2>/dev/null && log_ok "Killed orphaned process on port $port (PID $pid)" || true
    fi
  done

  # 3. Stop Docker Mailhog if running
  docker rm -f frndos-mailhog 2>/dev/null || true

  # 4. Clean up stale PID files
  rm -f "$PID_DIR"/*.pid 2>/dev/null

  echo ""
  log_ok "All services stopped."
}

# ── Status ───────────────────────────────────────────────────────────────────
show_status() {
  echo -e "\n${BOLD}Service Status${NC}\n"
  for name in api api-queue web ai-service data-service hocuspocus mailhog; do
    [[ "$name" != hocuspocus || -d "$SCRIPT_DIR/hocuspocus" ]] || continue
    local pid
    pid=$(read_pid "$name")
    if is_running "$pid"; then
      log_ok "$name — running (PID $pid)"
    else
      log_warn "$name — not running"
    fi
  done
  echo ""

  echo -e "${BOLD}Health Checks${NC}\n"
  # API: check /api endpoint
  local api_code
  api_code=$(curl -so /dev/null -w "%{http_code}" http://localhost:9191/api 2>/dev/null || echo "000")
  [[ "$api_code" != "000" ]] && log_ok "API (9191) — HTTP $api_code" || log_warn "API (9191) — down"

  curl -sf http://localhost:3000 &>/dev/null && log_ok "Frontend (3000)" || log_warn "Frontend (3000) — down"
  curl -sf http://localhost:8000/health &>/dev/null && log_ok "AI Service (8000)" || log_warn "AI Service (8000) — down"

  # Data Service: 401 = auth-protected but running
  local data_code
  data_code=$(curl -so /dev/null -w "%{http_code}" http://localhost:9999/api/v1/health/ 2>/dev/null || echo "000")
  [[ "$data_code" == "200" || "$data_code" == "401" ]] && log_ok "Data Service (9999) — HTTP $data_code" || log_warn "Data Service (9999) — down"

  if [[ -d "$SCRIPT_DIR/hocuspocus" ]]; then
    if [[ -n "$HOCUSPOCUS_PORT" ]]; then
      local collab_code
      collab_code=$(curl -so /dev/null -w "%{http_code}" "http://localhost:$HOCUSPOCUS_PORT/health" 2>/dev/null || echo "000")
      [[ "$collab_code" == "200" ]] && log_ok "Hocuspocus ($HOCUSPOCUS_PORT) — HTTP 200" || log_warn "Hocuspocus ($HOCUSPOCUS_PORT) — down"
    else
      log_warn "Hocuspocus — needs .env, Node >= 20.12 and a valid, non-reserved PORT"
    fi
  fi

  pg_isready -h localhost -p 5432 &>/dev/null && log_ok "PostgreSQL (5432)" || log_warn "PostgreSQL (5432) — down"
  redis-cli ping &>/dev/null && log_ok "Redis" || log_warn "Redis — down"
}

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  echo -e "\n${BOLD}Preflight Checks${NC}\n"
  local errors=0

  # Check tools (installed by /onboard Step 2)
  for cmd in php bun python3; do
    command -v "$cmd" &>/dev/null && log_ok "$cmd found" || { log_err "$cmd missing — re-run /onboard Step 2 to install it"; errors=$((errors+1)); }
  done

  echo ""

  # Check service directories + env files
  [[ -d "$SCRIPT_DIR/api" ]] && log_ok "api/ exists" || log_warn "api/ not found — skipping"
  [[ -d "$SCRIPT_DIR/web" ]] && log_ok "web/ exists" || log_warn "web/ not found — skipping"
  [[ -d "$SCRIPT_DIR/ai-service" ]] && log_ok "ai-service/ exists" || log_warn "ai-service/ not found — skipping"
  [[ -d "$SCRIPT_DIR/data-service" ]] && log_ok "data-service/ exists" || log_warn "data-service/ not found — skipping"
  [[ -d "$SCRIPT_DIR/hocuspocus" ]] && log_ok "hocuspocus/ exists" || log_warn "hocuspocus/ not found — skipping"

  echo ""

  [[ ! -d "$SCRIPT_DIR/api" ]] || [[ -f "$SCRIPT_DIR/api/.env" ]] && log_ok "api/.env exists" || log_warn "api/.env missing — API won't start"
  [[ ! -d "$SCRIPT_DIR/web" ]] || [[ -f "$SCRIPT_DIR/web/.env.local" ]] && log_ok "web/.env.local exists" || log_warn "web/.env.local missing"
  [[ ! -d "$SCRIPT_DIR/ai-service" ]] || [[ -f "$SCRIPT_DIR/ai-service/.env" ]] && log_ok "ai-service/.env exists" || log_warn "ai-service/.env missing"
  [[ ! -d "$SCRIPT_DIR/data-service" ]] || [[ -f "$SCRIPT_DIR/data-service/.env" ]] && log_ok "data-service/.env exists" || log_warn "data-service/.env missing"
  [[ ! -d "$SCRIPT_DIR/hocuspocus" ]] || [[ -f "$SCRIPT_DIR/hocuspocus/.env" ]] && log_ok "hocuspocus/.env exists" || log_warn "hocuspocus/.env missing"

  echo ""

  if [[ -d "$SCRIPT_DIR/hocuspocus" ]]; then
    if [[ -z "$HOCUSPOCUS_PORT" ]] || ! command -v npm &>/dev/null; then
      log_warn "Skipping Hocuspocus: needs .env, Node >= 20.12/npm and a valid, non-reserved PORT; collaboration unavailable"
    fi
  fi

  # Check port conflicts
  check_ports || true

  [[ $errors -gt 0 ]] && { log_err "$errors required tools missing. Install them (see /onboard Step 2)."; exit 1; }
  echo ""
}

# ── Start ────────────────────────────────────────────────────────────────────
start_all() {
  echo -e "\n${BOLD}Starting frndOS services...${NC}\n"

  # API Server
  if [[ -d "$SCRIPT_DIR/api" ]] && [[ -f "$SCRIPT_DIR/api/.env" ]]; then
    (cd "$SCRIPT_DIR/api" && php artisan optimize:clear && php artisan optimize && php artisan serve --port=9191 > "$LOG_DIR/api.log" 2>&1) &
    save_pid "api" $!
    log_ok "API started on :9191"
  else
    log_warn "Skipping API (missing dir or .env)"
  fi

  # API Queue Worker
  if [[ -d "$SCRIPT_DIR/api" ]] && [[ -f "$SCRIPT_DIR/api/.env" ]]; then
    (cd "$SCRIPT_DIR/api" && php artisan queue:work database \
      --timeout=3000 --tries=5 --queue=high,low,default,subscriptions > "$LOG_DIR/api-queue.log" 2>&1) &
    save_pid "api-queue" $!
    log_ok "API queue worker started"
  fi

  # Frontend
  if [[ -d "$SCRIPT_DIR/web" ]]; then
    (cd "$SCRIPT_DIR/web" && bun dev > "$LOG_DIR/web.log" 2>&1) &
    save_pid "web" $!
    log_ok "Frontend started on :3000"
  else
    log_warn "Skipping Frontend (missing dir)"
  fi

  # AI Service (uses fastapi dev, NOT uvicorn directly)
  if [[ -d "$SCRIPT_DIR/ai-service" ]] && [[ -f "$SCRIPT_DIR/ai-service/.env" ]]; then
    (cd "$SCRIPT_DIR/ai-service" && source .venv/bin/activate 2>/dev/null; fastapi dev > "$LOG_DIR/ai-service.log" 2>&1) &
    save_pid "ai-service" $!
    log_ok "AI Service started on :8000"
  else
    log_warn "Skipping AI Service (missing dir or .env)"
  fi

  # Data Service (entry point is app.main:app, NOT main:app)
  if [[ -d "$SCRIPT_DIR/data-service" ]] && [[ -f "$SCRIPT_DIR/data-service/.env" ]]; then
    (cd "$SCRIPT_DIR/data-service" && source .venv/bin/activate 2>/dev/null; \
      uvicorn app.main:app --reload --port 9999 > "$LOG_DIR/data-service.log" 2>&1) &
    save_pid "data-service" $!
    log_ok "Data Service started on :9999"
  else
    log_warn "Skipping Data Service (missing dir or .env)"
  fi

  # Hocuspocus (collaboration server — needs the API up for auth; stores updates in its Postgres)
  if [[ -d "$SCRIPT_DIR/hocuspocus" ]] && [[ -f "$SCRIPT_DIR/hocuspocus/.env" ]]; then
    if [[ -n "$HOCUSPOCUS_PORT" ]] && command -v npm &>/dev/null && [[ -z "$(port_pid "$HOCUSPOCUS_PORT")" ]]; then
      set -m
      (cd "$SCRIPT_DIR/hocuspocus" && PORT="$HOCUSPOCUS_PORT" exec npm run dev > "$LOG_DIR/hocuspocus.log" 2>&1) &
      local pid=$!
      save_pid "hocuspocus" "$pid"
      LC_ALL=C ps -p "$pid" -o lstart= > "$PID_DIR/hocuspocus.started" 2>/dev/null || true
      set +m
      log_ok "Hocuspocus started on :$HOCUSPOCUS_PORT"
    else
      log_warn "Skipping Hocuspocus (needs npm, valid config and a free PORT; see --check)"
    fi
  else
    log_warn "Skipping Hocuspocus (missing dir or .env)"
  fi

  # Mailhog (email testing for API)
  if command -v mailhog &>/dev/null; then
    (mailhog > "$LOG_DIR/mailhog.log" 2>&1) &
    save_pid "mailhog" $!
    log_ok "Mailhog started on :1025 (SMTP) / :8025 (UI)"
  elif command -v docker &>/dev/null; then
    docker run -d --name frndos-mailhog -p 1025:1025 -p 8025:8025 mailhog/mailhog > /dev/null 2>&1 && \
      log_ok "Mailhog started via Docker on :1025 / :8025" || log_warn "Skipping Mailhog (Docker failed)"
  else
    log_warn "Skipping Mailhog (not installed — brew install mailhog OR use Docker)"
  fi

  echo ""
  echo -e "${BOLD}All available services started.${NC}"
  echo ""
  echo "  Endpoints:"
  echo "    API Server    → http://localhost:9191"
  echo "    Frontend      → http://localhost:3000"
  echo "    AI Service    → http://localhost:8000"
  echo "    Data Service  → http://localhost:9999"
  if [[ -n "$HOCUSPOCUS_PORT" ]]; then
    echo "    Hocuspocus    → ws://localhost:$HOCUSPOCUS_PORT (health: http://localhost:$HOCUSPOCUS_PORT/health)"
  fi
  echo "    Mailhog UI    → http://localhost:8025"
  echo ""
  echo "  Logs:    tail -f $LOG_DIR/<service>.log"
  echo "  Status:  ./run-all.sh --status"
  echo "  Stop:    ./run-all.sh --stop"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --stop)        stop_all ;;
  --status)      show_status ;;
  --check)       preflight ;;
  --kill-ports)  kill_ports ;;
  --help|-h)
    echo ""
    echo "  Usage: ./run-all.sh [command]"
    echo ""
    echo "  Commands:"
    echo "    (no args)      Run preflight checks, then start all services"
    echo "    --check        Run preflight checks only"
    echo "    --status       Show status of all services + health checks"
    echo "    --stop         Stop the services this script starts (never ${SHARED_PORTS[*]})"
    echo "    --kill-ports   Kill processes on ports ${OWNED_PORTS[*]}"
    echo "                   (never ${SHARED_PORTS[*]} — shared infrastructure)"
    echo "    --help         Show this help message"
    echo ""
    ;;
  *)             preflight && start_all ;;
esac
