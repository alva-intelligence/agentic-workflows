#!/usr/bin/env bash
# run-all.sh — Start all frndOS services concurrently
# Usage: ./run-all.sh [--stop] [--status] [--check]
#
# MUST be run inside `nix develop` shell for all tools to be available.
# Services: API (9191), Frontend (3000), AI Service (8000), Data Service (9999)

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

# ── Port conflict check ──────────────────────────────────────────────────────
check_ports() {
  local conflicts=0
  for port in 9191 3000 8000 9999; do
    local pid
    pid=$(lsof -ti :"$port" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
      local cmd
      cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
      log_warn "Port $port in use by PID $pid ($cmd)"
      conflicts=$((conflicts + 1))
    fi
  done
  if [[ $conflicts -gt 0 ]]; then
    echo ""
    log_warn "$conflicts port conflict(s). Stop existing processes or use: ./run-all.sh --kill-ports"
    return 1
  fi
  return 0
}

# ── Kill conflicting ports ───────────────────────────────────────────────────
kill_ports() {
  for port in 9191 3000 8000 9999; do
    local pid
    pid=$(lsof -ti :"$port" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null && log_ok "Killed PID $pid on port $port" || log_warn "Failed to kill PID $pid"
    fi
  done
}

# ── Stop ─────────────────────────────────────────────────────────────────────
stop_all() {
  echo -e "\n${BOLD}Stopping all services...${NC}\n"

  # 1. Stop tracked PIDs
  for name in api api-queue web ai-service data-service mailhog; do
    local pid
    pid=$(read_pid "$name")
    if is_running "$pid"; then
      kill "$pid" 2>/dev/null && log_ok "Stopped $name (PID $pid)" || log_warn "Failed to stop $name"
      rm -f "$PID_DIR/$name.pid"
    fi
  done

  # 2. Kill anything still on our ports (catches orphaned processes)
  for port in 9191 3000 8000 9999 1025 8025; do
    local pid
    pid=$(lsof -ti :"$port" 2>/dev/null || true)
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
  for name in api api-queue web ai-service data-service mailhog; do
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

  pg_isready -h localhost -p 5432 &>/dev/null && log_ok "PostgreSQL (5432)" || log_warn "PostgreSQL (5432) — down"
  redis-cli ping &>/dev/null && log_ok "Redis" || log_warn "Redis — down"
}

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  echo -e "\n${BOLD}Preflight Checks${NC}\n"
  local errors=0

  # Check tools (should be in nix shell)
  for cmd in php bun python3; do
    command -v "$cmd" &>/dev/null && log_ok "$cmd found" || { log_err "$cmd missing — are you inside 'nix develop'?"; errors=$((errors+1)); }
  done

  echo ""

  # Check service directories + env files
  [[ -d "$SCRIPT_DIR/api" ]] && log_ok "api/ exists" || log_warn "api/ not found — skipping"
  [[ -d "$SCRIPT_DIR/web" ]] && log_ok "web/ exists" || log_warn "web/ not found — skipping"
  [[ -d "$SCRIPT_DIR/ai-service" ]] && log_ok "ai-service/ exists" || log_warn "ai-service/ not found — skipping"
  [[ -d "$SCRIPT_DIR/data-service" ]] && log_ok "data-service/ exists" || log_warn "data-service/ not found — skipping"

  echo ""

  [[ ! -d "$SCRIPT_DIR/api" ]] || [[ -f "$SCRIPT_DIR/api/.env" ]] && log_ok "api/.env exists" || log_warn "api/.env missing — API won't start"
  [[ ! -d "$SCRIPT_DIR/web" ]] || [[ -f "$SCRIPT_DIR/web/.env.local" ]] && log_ok "web/.env.local exists" || log_warn "web/.env.local missing"
  [[ ! -d "$SCRIPT_DIR/ai-service" ]] || [[ -f "$SCRIPT_DIR/ai-service/.env" ]] && log_ok "ai-service/.env exists" || log_warn "ai-service/.env missing"
  [[ ! -d "$SCRIPT_DIR/data-service" ]] || [[ -f "$SCRIPT_DIR/data-service/.env" ]] && log_ok "data-service/.env exists" || log_warn "data-service/.env missing"

  echo ""

  # Check port conflicts
  check_ports || true

  [[ $errors -gt 0 ]] && { log_err "$errors required tools missing. Run 'nix develop' first."; exit 1; }
  echo ""
}

# ── Start ────────────────────────────────────────────────────────────────────
start_all() {
  echo -e "\n${BOLD}Starting frndOS services...${NC}\n"

  # API Server
  if [[ -d "$SCRIPT_DIR/api" ]] && [[ -f "$SCRIPT_DIR/api/.env" ]]; then
    (cd "$SCRIPT_DIR/api" && php artisan serve --port=9191 > "$LOG_DIR/api.log" 2>&1) &
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
    echo "    --stop         Stop all running services"
    echo "    --kill-ports   Kill processes on ports 9191, 3000, 8000, 9999"
    echo "    --help         Show this help message"
    echo ""
    ;;
  *)             preflight && start_all ;;
esac
