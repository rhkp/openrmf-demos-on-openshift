#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

: "${RMF_LAUNCH_FILE:?RMF_LAUNCH_FILE must be set (e.g. office.launch.xml)}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"
DISPLAY_NUM="${RMF_DISPLAY_NUM:-99}"
VNC_PORT="${RMF_VNC_PORT:-5900}"
SCREEN_SIZE="${RMF_VNC_WIDTH:-1280}x${RMF_VNC_HEIGHT:-720}x24"

export DISPLAY=":${DISPLAY_NUM}"
export QT_X11_NO_MITSHM=1
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

echo "[simulation] Starting Xvfb on ${DISPLAY} (${SCREEN_SIZE})..."
Xvfb "${DISPLAY}" -screen 0 "${SCREEN_SIZE}" -ac +extension GLX +render -noreset &
XVFB_PID=$!

cleanup() {
  kill "${XVFB_PID}" "${VNC_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
  if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

echo "[simulation] Starting x11vnc on port ${VNC_PORT} (noVNC sidecar connects via pod localhost)..."
x11vnc -display "${DISPLAY}" -forever -shared -nopw -rfbport "${VNC_PORT}" -noxdamage &
VNC_PID=$!

echo "[simulation] Launching RMF ${RMF_LAUNCH_FILE} with virtual display (Gazebo/RViz visible via noVNC)..."
echo "[simulation] RMF server_uri=${SERVER_URI}"
exec ros2 launch rmf_demos_gz "${RMF_LAUNCH_FILE}" \
  use_sim_time:=true \
  headless:=0 \
  "server_uri:=${SERVER_URI}"
