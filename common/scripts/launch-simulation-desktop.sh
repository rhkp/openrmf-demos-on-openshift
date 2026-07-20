#!/usr/bin/env bash
# Gazebo + RViz on the host X display (e.g. xrdp / local desktop). For Podman local validation.
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

: "${RMF_LAUNCH_FILE:?RMF_LAUNCH_FILE must be set (e.g. office.launch.xml)}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"
export DISPLAY="${DISPLAY:-:0}"
export QT_X11_NO_MITSHM=1
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

echo "[simulation] Launching RMF ${RMF_LAUNCH_FILE} on DISPLAY=${DISPLAY}..."
echo "[simulation] RMF server_uri=${SERVER_URI}"
exec ros2 launch rmf_demos_gz "${RMF_LAUNCH_FILE}" \
  use_sim_time:=true \
  headless:=0 \
  "server_uri:=${SERVER_URI}"
