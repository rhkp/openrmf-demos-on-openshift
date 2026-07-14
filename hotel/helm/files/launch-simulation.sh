#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

# Headless Gazebo — no X11/display required on OpenShift
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

: "${RMF_LAUNCH_FILE:?RMF_LAUNCH_FILE must be set (e.g. office.launch.xml)}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"

echo "[simulation] Launching RMF ${RMF_LAUNCH_FILE} (headless)..."
echo "[simulation] RMF server_uri=${SERVER_URI}"
exec ros2 launch rmf_demos_gz "${RMF_LAUNCH_FILE}" \
  use_sim_time:=true \
  headless:=1 \
  "server_uri:=${SERVER_URI}"
