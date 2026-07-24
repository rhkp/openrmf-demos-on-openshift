#!/usr/bin/env bash
# Task dispatch for robot-as-pod mode
# This script can be used to dispatch tasks to individual robot pods
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

DISPATCH_MARKER="${DISPATCH_MARKER:-/opt/rmf/.ros/.office-robot-mode-dispatch-done}"

if [[ -f "${DISPATCH_MARKER}" ]]; then
  echo "[office/robot-mode/dispatch] Patrol already submitted; holding container open."
  exec tail -f /dev/null
fi

# Extra buffer for distributed robots to initialize
READY_WAIT_SECONDS="${READY_WAIT_SECONDS:-60}"
STARTUP_WAIT_SECONDS="${STARTUP_WAIT_SECONDS:-30}"

if (( STARTUP_WAIT_SECONDS > 0 )); then
  echo "[office/robot-mode/dispatch] Initial delay ${STARTUP_WAIT_SECONDS}s..."
  sleep "${STARTUP_WAIT_SECONDS}"
fi

# Wait for robot fleet to be ready (all robots connected)
echo "[office/robot-mode/dispatch] Waiting for robot fleet to be ready..."
/opt/rmf/scripts/wait-for-topic.sh /fleet_states
echo "[office/robot-mode/dispatch] Fleet ready; waiting ${READY_WAIT_SECONDS}s for all robots to initialize..."
sleep "${READY_WAIT_SECONDS}"

echo "[office/robot-mode/dispatch] Dispatching patrol to robot fleet: coe -> lounge (3 loops)..."
ros2 run rmf_demos_tasks dispatch_patrol \
  -p coe lounge \
  -n 3 \
  --use_sim_time

touch "${DISPATCH_MARKER}"
echo "[office/robot-mode/dispatch] Patrol submitted to robot pods; holding container open."
exec tail -f /dev/null