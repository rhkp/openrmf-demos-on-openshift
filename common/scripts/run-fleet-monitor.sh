#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

/opt/rmf/scripts/wait-for-topic.sh /fleet_states

echo "[fleet-monitor] Subscribing to fleet states..."
exec python3 /opt/rmf/scripts/fleet-monitor.py
