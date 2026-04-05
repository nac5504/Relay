#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"
PID_FILE="$SCRIPT_DIR/.relay-backend.pid"
LOG_FILE="$BACKEND_DIR/relay-backend.log"

echo "==> Relay Startup"

# 1. Check Docker daemon
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is not running. Start Docker Desktop and try again."
  exit 1
fi
echo "  [✓] Docker is running"

# 2. Clean up stale relay-agent containers
STALE=$(docker ps -a --filter name=relay-agent -q 2>/dev/null || true)
if [ -n "$STALE" ]; then
  echo "$STALE" | while read -r id; do docker rm -f "$id" >/dev/null 2>&1 || true; done
  echo "  [✓] Cleaned up stale containers"
else
  echo "  [✓] No stale containers"
fi

# 3. Check if backend is already running on port 3001
if lsof -ti :3001 >/dev/null 2>&1; then
  echo "  [!] Port 3001 already in use — backend may already be running"
  echo "==> Done (backend was already running)"
  exit 0
fi

# 4. Start backend
cd "$BACKEND_DIR"
echo "  [~] Starting backend (npm run dev)..."
npm run dev > "$LOG_FILE" 2>&1 &
BACKEND_PID=$!
echo "$BACKEND_PID" > "$PID_FILE"
cd "$SCRIPT_DIR"

# 5. Wait for health check
echo -n "  [~] Waiting for backend"
for i in $(seq 1 30); do
  if curl -s http://localhost:3001/health >/dev/null 2>&1; then
    echo ""
    echo "  [✓] Backend ready on http://localhost:3001 (PID $BACKEND_PID)"
    echo "==> Relay is running. Use ./kill.sh to stop."
    exit 0
  fi
  echo -n "."
  sleep 1
done

echo ""
echo "ERROR: Backend failed to start within 30s. Check $LOG_FILE"
kill "$BACKEND_PID" 2>/dev/null || true
rm -f "$PID_FILE"
exit 1
