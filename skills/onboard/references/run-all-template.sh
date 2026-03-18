#!/usr/bin/env bash
# run-all.sh — Start all frndOS services concurrently
# Usage: ./run-all.sh [--stop] [--status] [--check]

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
read_pid() { [[ -f "$PID_DIR/$1.pid" ]] && cat "$PID_DIR/$1.pid"; }
is_running() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

# ── Stop ─────────────────────────────────────────────────────────────────────
stop_all() {
  echo -e "\n${BOLD}Stopping all services...${NC}\n"
  for name in api web ai-service data-service; do
    pid=$(read_pid "$name")
    if is_running "$pid"; then
      kill "$pid" 2>/dev/null && log_ok "Stopped $name (PID $pid)" || log_warn "Failed to stop $name"
      rm -f "$PID_DIR/$name.pid"
    fi
  done
}

# ── Status ───────────────────────────────────────────────────────────────────
show_status() {
  echo -e "\n${BOLD}Service Status${NC}\n"
  for name in api web ai-service data-service; do
    pid=$(read_pid "$name")
    if is_running "$pid"; then
      log_ok "$name — running (PID $pid)"
    else
      log_warn "$name — not running"
    fi
  done
  echo ""

  echo -e "${BOLD}Health Checks${NC}\n"
  curl -sf http://localhost:9191/health &>/dev/null && log_ok "API (9191)" || log_warn "API (9191) — down"
  curl -sf http://localhost:3000 &>/dev/null && log_ok "Frontend (3000)" || log_warn "Frontend (3000) — down"
  curl -sf http://localhost:8000/health &>/dev/null && log_ok "AI Service (8000)" || log_warn "AI Service (8000) — down"
  curl -sf http://localhost:9999/health &>/dev/null && log_ok "Data Service (9999)" || log_warn "Data Service (9999) — down"
  pg_isready -h localhost -p 5432 &>/dev/null && log_ok "PostgreSQL (5432)" || log_warn "PostgreSQL (5432) — down"
  redis-cli ping &>/dev/null && log_ok "Redis" || log_warn "Redis — down"
}

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  echo -e "\n${BOLD}Preflight Checks${NC}\n"
  local errors=0

  for cmd in php bun python3; do
    command -v "$cmd" &>/dev/null && log_ok "$cmd found" || { log_err "$cmd missing"; errors=$((errors+1)); }
  done

  [[ -d "$SCRIPT_DIR/api" ]] && log_ok "api/ exists" || log_warn "api/ not found"
  [[ -d "$SCRIPT_DIR/web" ]] && log_ok "web/ exists" || log_warn "web/ not found"

  [[ -f "$SCRIPT_DIR/api/.env" ]] && log_ok "api/.env exists" || log_warn "api/.env missing"
  [[ -f "$SCRIPT_DIR/web/.env.local" ]] && log_ok "web/.env.local exists" || log_warn "web/.env.local missing"

  [[ $errors -gt 0 ]] && { log_err "$errors required tools missing"; exit 1; }
  echo ""
}

# ── Start ────────────────────────────────────────────────────────────────────
start_all() {
  echo -e "\n${BOLD}Starting frndOS services...${NC}\n"

  # API
  if [[ -d "$SCRIPT_DIR/api" ]] && [[ -f "$SCRIPT_DIR/api/.env" ]]; then
    (cd "$SCRIPT_DIR/api" && php artisan serve --port=9191 > "$LOG_DIR/api.log" 2>&1) &
    save_pid "api" $!
    log_ok "API started on :9191"
  else
    log_warn "Skipping API (missing dir or .env)"
  fi

  # Frontend
  if [[ -d "$SCRIPT_DIR/web" ]]; then
    (cd "$SCRIPT_DIR/web" && bun dev > "$LOG_DIR/web.log" 2>&1) &
    save_pid "web" $!
    log_ok "Frontend started on :3000"
  else
    log_warn "Skipping Frontend (missing dir)"
  fi

  # AI Service
  if [[ -d "$SCRIPT_DIR/ai-service" ]] && [[ -f "$SCRIPT_DIR/ai-service/.env" ]]; then
    (cd "$SCRIPT_DIR/ai-service" && source venv/bin/activate 2>/dev/null; uvicorn main:app --port=8000 --reload > "$LOG_DIR/ai-service.log" 2>&1) &
    save_pid "ai-service" $!
    log_ok "AI Service started on :8000"
  else
    log_warn "Skipping AI Service (missing dir or .env)"
  fi

  # Data Service
  if [[ -d "$SCRIPT_DIR/data-service" ]] && [[ -f "$SCRIPT_DIR/data-service/.env" ]]; then
    (cd "$SCRIPT_DIR/data-service" && source venv/bin/activate 2>/dev/null; uvicorn main:app --port=9999 --reload > "$LOG_DIR/data-service.log" 2>&1) &
    save_pid "data-service" $!
    log_ok "Data Service started on :9999"
  else
    log_warn "Skipping Data Service (missing dir or .env)"
  fi

  echo -e "\n${BOLD}All available services started.${NC}"
  echo "Logs: $LOG_DIR/"
  echo "Stop: ./run-all.sh --stop"
}

# ── Main ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --stop)   stop_all ;;
  --status) show_status ;;
  --check)  preflight ;;
  *)        preflight && start_all ;;
esac
