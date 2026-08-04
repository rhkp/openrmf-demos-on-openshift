#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

DISPATCH_MARKER="${DISPATCH_MARKER:-/opt/rmf/.ros/.airport-collision-dispatch-done}"

if [[ -f "${DISPATCH_MARKER}" ]]; then
  echo "[airport/collision-test] Goals already dispatched; holding container open."
  exec tail -f /dev/null
fi

READY_WAIT_SECONDS="${READY_WAIT_SECONDS:-120}"
STARTUP_WAIT_SECONDS="${STARTUP_WAIT_SECONDS:-45}"

if (( STARTUP_WAIT_SECONDS > 0 )); then
  echo "[airport/collision-test] Initial delay ${STARTUP_WAIT_SECONDS}s for fleet adapters..."
  sleep "${STARTUP_WAIT_SECONDS}"
fi

/opt/rmf/scripts/wait-for-topic.sh /fleet_states
echo "[airport/collision-test] Simulation ready; waiting ${READY_WAIT_SECONDS}s for adapters..."
sleep "${READY_WAIT_SECONDS}"

echo "[airport/collision-test] Dispatching opposing goals for collision avoidance demo..."
touch "${DISPATCH_MARKER}"

python3 /opt/rmf/scripts/dispatch-opposing-goals.py --ros-args \
  -p use_sim_time:=true \
  -p robot_0:=tinyRobot_0 \
  -p robot_1:=tinyRobot_1
