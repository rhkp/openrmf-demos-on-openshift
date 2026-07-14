#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

DISPATCH_MARKER="${DISPATCH_MARKER:-/opt/rmf/.ros/.office-dispatch-done}"

if [[ -f "${DISPATCH_MARKER}" ]]; then
  echo "[office/dispatch] Patrol already submitted; holding container open."
  exec tail -f /dev/null
fi

# Extra buffer after /fleet_states appears so adapters finish initializing
READY_WAIT_SECONDS="${READY_WAIT_SECONDS:-30}"
STARTUP_WAIT_SECONDS="${STARTUP_WAIT_SECONDS:-0}"

if (( STARTUP_WAIT_SECONDS > 0 )); then
  echo "[office/dispatch] Initial delay ${STARTUP_WAIT_SECONDS}s..."
  sleep "${STARTUP_WAIT_SECONDS}"
fi

/opt/rmf/scripts/wait-for-topic.sh /fleet_states
echo "[office/dispatch] Simulation ready; waiting ${READY_WAIT_SECONDS}s for adapters..."
sleep "${READY_WAIT_SECONDS}"

echo "[office/dispatch] Dispatching patrol: coe -> lounge (3 loops)..."
ros2 run rmf_demos_tasks dispatch_patrol \
  -p coe lounge \
  -n 3 \
  --use_sim_time

touch "${DISPATCH_MARKER}"
echo "[office/dispatch] Patrol submitted; holding container open."
exec tail -f /dev/null
