#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

# Headless Gazebo — no X11/display required on OpenShift
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"

echo "[simulation-world] Launching office world-only (no fleet adapter — robots run in separate pods)..."
echo "[simulation-world] RMF server_uri=${SERVER_URI}"

# Launch world + core RMF services, but NOT the fleet adapter
exec ros2 launch /opt/rmf/demos/common/launch/office_world_only.launch.xml \
  use_sim_time:=true \
  headless:=1 \
  "server_uri:=${SERVER_URI}"