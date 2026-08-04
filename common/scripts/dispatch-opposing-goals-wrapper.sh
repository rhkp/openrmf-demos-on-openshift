#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

ROBOT_0="${ROBOT_0:-tinyRobot1}"
ROBOT_1="${ROBOT_1:-tinyRobot2}"
GOAL_DISTANCE="${GOAL_DISTANCE:-10.0}"
READY_WAIT_SECONDS="${READY_WAIT_SECONDS:-60}"

echo "[collision-test] Waiting ${READY_WAIT_SECONDS}s for fleet adapters..."
sleep "${READY_WAIT_SECONDS}"

/opt/rmf/scripts/wait-for-topic.sh /fleet_states

echo "[collision-test] Dispatching opposing goals: ${ROBOT_0} <-> ${ROBOT_1}, distance=${GOAL_DISTANCE}m"

exec python3 /opt/rmf/scripts/dispatch-opposing-goals.py --ros-args \
  -p use_sim_time:=true \
  -p robot_0:="${ROBOT_0}" \
  -p robot_1:="${ROBOT_1}" \
  -p goal_distance:="${GOAL_DISTANCE}"
