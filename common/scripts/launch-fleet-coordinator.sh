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

# Simple fleet coordinator for distributed robot pods
# In robot-as-pod mode, the individual robots handle their own fleet adapters
# This coordinator primarily monitors and logs fleet status

echo "[fleet-coordinator] Fleet coordinator ready for ${RMF_WORLD_NAME}"
echo "[fleet-coordinator] Monitoring fleet states..."

# Simple monitoring loop - wait for fleet states topic and log activity
while true; do
  if ros2 topic list 2>/dev/null | grep -q "/fleet_states"; then
    echo "[fleet-coordinator] Fleet states topic available - robots are active"
    # Monitor fleet states periodically
    ros2 topic echo /fleet_states --once 2>/dev/null || echo "[fleet-coordinator] Waiting for fleet state data..."
  else
    echo "[fleet-coordinator] Waiting for fleet states topic..."
  fi
  sleep 30
done