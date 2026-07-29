#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

# VNC + world-only for robot-as-pod mode with GPU sensor visualization
# gz-sim runs headless (no GUI) with DISPLAY unset so ogre2 uses EGL+NVIDIA GPU
# for gpu_lidar render-to-texture. RViz2 provides SLAM/lidar visualization on VNC.
DISPLAY_NUM="${DISPLAY:-:99}"
export RMF_VNC_PORT="${RMF_VNC_PORT:-5900}"
export RMF_VNC_WIDTH="${RMF_VNC_WIDTH:-1280}"
export RMF_VNC_HEIGHT="${RMF_VNC_HEIGHT:-720}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"

echo "[simulation-world] Starting Xvfb on ${DISPLAY_NUM} (${RMF_VNC_WIDTH}x${RMF_VNC_HEIGHT}x24)..."
# Force mesa for Xvfb — NVIDIA EGL crashes the software X server
LIBGL_ALWAYS_SOFTWARE=1 __EGL_VENDOR_LIBRARY_FILENAMES="" \
  Xvfb "${DISPLAY_NUM}" -screen 0 "${RMF_VNC_WIDTH}x${RMF_VNC_HEIGHT}x24" +extension GLX &
XVFB_PID=$!

echo "[simulation-world] Starting x11vnc on port ${RMF_VNC_PORT}..."
x11vnc -display "${DISPLAY_NUM}" -rfbport "${RMF_VNC_PORT}" -shared -forever -nopw &
X11VNC_PID=$!

cleanup() {
  echo "[simulation-world] Cleaning up..."
  kill ${GLOBAL_TF_PID:-} 2>/dev/null || true
  kill ${RVIZ_PID:-} 2>/dev/null || true
  kill ${OPENBOX_PID:-} 2>/dev/null || true
  kill ${X11VNC_PID} 2>/dev/null || true
  kill ${XVFB_PID} 2>/dev/null || true
  kill ${ZENOHD_PID:-} 2>/dev/null || true
}
trap cleanup EXIT

sleep 2

# Start window manager so user can move/resize windows in noVNC
echo "[simulation-world] Starting openbox window manager..."
DISPLAY="${DISPLAY_NUM}" openbox &
OPENBOX_PID=$!

# Start local Zenoh daemon connected to central router for cross-pod topic discovery
if [ -n "${ZENOH_ROUTER_ENDPOINT:-}" ]; then
  echo "[simulation-world] Starting local Zenoh daemon (peering with ${ZENOH_ROUTER_ENDPOINT})..."
  export ZENOH_ROUTER_CONFIG_OVERRIDE="connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];scouting/multicast/enabled=false"
  ros2 run rmw_zenoh_cpp rmw_zenohd &
  ZENOHD_PID=$!
  sleep 8
  export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"tcp/localhost:7447\"];scouting/multicast/enabled=false"
fi

echo "[simulation-world] Launching office world-only HEADLESS (EGL+GPU rendering)..."
echo "[simulation-world] RMF server_uri=${SERVER_URI}"

# Unset DISPLAY so ogre2 uses EGL (NVIDIA GPU) instead of GLX (Xvfb software mesa).
# This is critical for gpu_lidar render-to-texture to produce scan data.
env -u DISPLAY ros2 launch /opt/rmf/demos/common/launch/office_world_only.launch.xml \
  use_sim_time:=true \
  headless:=1 \
  "server_uri:=${SERVER_URI}" &
SIM_PID=$!

# Wait for simulation to start
sleep 15

# Global TF publisher: publishes robot TF on global /tf for RViz
# (robot pods publish on namespaced /{robot}/tf for Nav2/SLAM)
echo "[simulation-world] Starting global TF publisher for RViz..."
python3 /opt/rmf/scripts/global_tf_publisher.py --ros-args -p use_sim_time:=true &
GLOBAL_TF_PID=$!

echo "[simulation-world] Starting RViz2 for SLAM/lidar visualization..."
DISPLAY="${DISPLAY_NUM}" rviz2 -d /opt/rmf/config/slam_rviz.rviz --ros-args -p use_sim_time:=true &
RVIZ_PID=$!

wait ${SIM_PID}
