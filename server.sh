#!/usr/bin/env bash
# Static file server for the Cubby live-installer rendezvous.
#
# Serves the repo root over HTTP so Caddy can reverse-proxy
# staging.justapoint.org/addons/cubby/* to it (see the Caddyfile carve-out).
#
#   ./server.sh start | stop | restart | status
#
# Port is 8090 by default; override with CUBBY_PORT.
set -euo pipefail

PORT="${CUBBY_PORT:-8090}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$ROOT/.run"
PIDFILE="$RUN_DIR/server.pid"
LOGFILE="$RUN_DIR/server.log"

mkdir -p "$RUN_DIR"

is_running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

start() {
  if is_running; then
    echo "already running (pid $(cat "$PIDFILE"), port $PORT)"
    return 0
  fi
  # Bind all interfaces so the Caddy container can reach it via
  # host.docker.internal; it's only meant to be reached through Caddy.
  nohup python3 -m http.server "$PORT" --directory "$ROOT" >"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"
  # Wait until the port is actually accepting, not just the process alive.
  for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; break; fi
    is_running || break
    sleep 0.1
  done
  if is_running; then
    echo "started (pid $(cat "$PIDFILE"), serving $ROOT on :$PORT)"
  else
    echo "failed to start — see $LOGFILE" >&2
    tail -n 20 "$LOGFILE" >&2 || true
    return 1
  fi
}

stop() {
  if ! is_running; then
    echo "not running"
    rm -f "$PIDFILE"
    return 0
  fi
  local pid; pid="$(cat "$PIDFILE")"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 25); do
    is_running || break
    sleep 0.2
  done
  is_running && kill -9 "$pid" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "stopped"
}

status() {
  if is_running; then
    echo "running (pid $(cat "$PIDFILE"), serving $ROOT on :$PORT)"
  else
    echo "stopped"
    return 1
  fi
}

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  status ;;
  *) echo "usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
