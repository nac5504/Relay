#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/.relay-backend.pid"

echo "==> Relay Shutdown"

# 1. Stop all relay-agent Docker containers
CONTAINERS=$(docker ps -a --filter name=relay-agent -q 2>/dev/null || true)
if [ -n "$CONTAINERS" ]; then
  echo "$CONTAINERS" | while read -r id; do docker rm -f "$id" >/dev/null 2>&1 || true; done
  echo "  [✓] Stopped relay-agent containers"
else
  echo "  [✓] No relay-agent containers running"
fi

# 2. Kill backend from PID file
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  if kill "$PID" 2>/dev/null; then
    echo "  [✓] Stopped backend (PID $PID)"
  else
    echo "  [!] Backend PID $PID was not running"
  fi
  rm -f "$PID_FILE"
fi

# 3. Fallback: kill anything on port 3001
PORT_PIDS=$(lsof -ti :3001 2>/dev/null || true)
if [ -n "$PORT_PIDS" ]; then
  echo "$PORT_PIDS" | while read -r pid; do kill "$pid" 2>/dev/null || true; done
  echo "  [✓] Killed remaining processes on port 3001"
fi

echo "==> Relay stopped."
