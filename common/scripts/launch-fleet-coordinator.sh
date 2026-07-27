#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"
WORLD_NAME="${RMF_WORLD_NAME:-office}"

echo "[fleet-coordinator] Starting centralized fleet coordination for ${WORLD_NAME}..."
echo "[fleet-coordinator] RMF server_uri=${SERVER_URI}"
echo "[fleet-coordinator] Zenoh router: ${ZENOH_ROUTER_ENDPOINT}"

# Configure Zenoh connection to central router
export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];scouting/multicast/enabled=false"

echo "[fleet-coordinator] Waiting for world simulation..."
/opt/rmf/scripts/wait-for-world.sh 300

echo "[fleet-coordinator] Launching fleet coordinator..."

# Launch the Python fleet coordinator
exec python3 /opt/rmf/scripts/fleet-coordinator.py