#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

DISPATCH_MARKER="${DISPATCH_MARKER:-/opt/rmf/.ros/.hotel-dispatch-done}"

if [[ -f "${DISPATCH_MARKER}" ]]; then
  echo "[hotel/dispatch] Patrol already submitted; holding container open."
  exec tail -f /dev/null
fi

READY_WAIT_SECONDS="${READY_WAIT_SECONDS:-90}"
STARTUP_WAIT_SECONDS="${STARTUP_WAIT_SECONDS:-30}"

if (( STARTUP_WAIT_SECONDS > 0 )); then
  echo "[hotel/dispatch] Initial delay ${STARTUP_WAIT_SECONDS}s for multi-fleet adapters..."
  sleep "${STARTUP_WAIT_SECONDS}"
fi

/opt/rmf/scripts/wait-for-topic.sh /fleet_states
echo "[hotel/dispatch] Simulation ready; waiting ${READY_WAIT_SECONDS}s for adapters..."
sleep "${READY_WAIT_SECONDS}"

echo "[hotel/dispatch] Dispatching patrol: restaurant -> L3_master_suite (1 loop)..."
for attempt in 1 2 3 4 5; do
  OUTPUT="$(ros2 run rmf_demos_tasks dispatch_patrol \
    -p restaurant L3_master_suite \
    -n 1 \
    --use_sim_time 2>&1)" || true
  echo "${OUTPUT}"
  if echo "${OUTPUT}" | grep -q "'success': True"; then
    echo "[hotel/dispatch] Patrol accepted on attempt ${attempt}."
    touch "${DISPATCH_MARKER}"
    echo "[hotel/dispatch] Patrol submitted; holding container open."
    exec tail -f /dev/null
  fi
  echo "[hotel/dispatch] Attempt ${attempt} did not get a response; retrying in 30s..."
  sleep 30
done

echo "[hotel/dispatch] Auto-dispatch failed after 5 attempts; holding container open."
echo "[hotel/dispatch] Submit manually: ros2 run rmf_demos_tasks dispatch_patrol -p restaurant L3_master_suite -n 1 --use_sim_time"
exec tail -f /dev/null
