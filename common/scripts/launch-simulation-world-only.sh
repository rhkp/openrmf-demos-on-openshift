#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

# Headless Gazebo — no X11/display required on OpenShift
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

: "${RMF_LAUNCH_FILE:?RMF_LAUNCH_FILE must be set (e.g. office.launch.xml)}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"

echo "[simulation-world] Launching RMF ${RMF_LAUNCH_FILE} (world-only, headless)..."
echo "[simulation-world] RMF server_uri=${SERVER_URI}"

# Launch the world simulation only (no fleet adapters, no robots spawned)
exec ros2 launch /opt/rmf/demos/common/launch/world_only.launch.xml \
  world_file:="${RMF_LAUNCH_FILE}" \
  use_sim_time:=true \
  headless:=1 \
  spawn_robots:=false \
  "server_uri:=${SERVER_URI}"