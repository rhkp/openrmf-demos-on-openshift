#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

# VNC + world-only for robot-as-pod mode with visualization
export DISPLAY="${DISPLAY:-:99}"
export RMF_VNC_PORT="${RMF_VNC_PORT:-5900}"
export RMF_VNC_WIDTH="${RMF_VNC_WIDTH:-1280}"
export RMF_VNC_HEIGHT="${RMF_VNC_HEIGHT:-720}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"

echo "[simulation-world] Starting Xvfb on ${DISPLAY} (${RMF_VNC_WIDTH}x${RMF_VNC_HEIGHT}x24)..."
Xvfb "${DISPLAY}" -screen 0 "${RMF_VNC_WIDTH}x${RMF_VNC_HEIGHT}x24" &
XVFB_PID=$!

echo "[simulation-world] Starting x11vnc on port ${RMF_VNC_PORT}..."
x11vnc -display "${DISPLAY}" -rfbport "${RMF_VNC_PORT}" -shared -forever -nopw &
X11VNC_PID=$!

cleanup() {
  echo "[simulation-world] Cleaning up..."
  kill ${X11VNC_PID} 2>/dev/null || true
  kill ${XVFB_PID} 2>/dev/null || true
}
trap cleanup EXIT

sleep 2

echo "[simulation-world] Launching office world-only with VNC (no fleet adapter — robots run in separate pods)..."
echo "[simulation-world] RMF server_uri=${SERVER_URI}"

# Launch world + core RMF services, but NOT the fleet adapter
exec ros2 launch /opt/rmf/demos/common/launch/office_world_only.launch.xml \
  use_sim_time:=true \
  headless:=0 \
  "server_uri:=${SERVER_URI}"