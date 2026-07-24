#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

# Required configuration
: "${RMF_WORLD_NAME:?RMF_WORLD_NAME must be set (e.g. office)}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"

echo "[fleet-coordinator] Starting fleet coordination for ${RMF_WORLD_NAME}..."
echo "[fleet-coordinator] RMF server_uri=${SERVER_URI}"

# Wait for world simulation to be ready
echo "[fleet-coordinator] Waiting for world simulation to be ready..."
/opt/rmf/scripts/wait-for-world.sh 300

# Launch fleet coordinator that manages distributed robot pods
exec ros2 launch /opt/rmf/demos/common/launch/fleet_coordinator.launch.xml \
  world_name:="${RMF_WORLD_NAME}" \
  use_sim_time:=true \
  "server_uri:=${SERVER_URI}"