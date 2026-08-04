#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

ROBOT_0="${ROBOT_0:-tinyRobot1}"
ROBOT_1="${ROBOT_1:-tinyRobot2}"
FLEET_NAME="${FLEET_NAME:-tinyRobot}"
ROBOT_0_DEST="${ROBOT_0_DEST:-wp_right}"
ROBOT_1_DEST="${ROBOT_1_DEST:-wp_left}"
READY_WAIT_SECONDS="${READY_WAIT_SECONDS:-90}"

echo "[rmf-patrol] Waiting ${READY_WAIT_SECONDS}s for fleet adapters + traffic schedule..."
sleep "${READY_WAIT_SECONDS}"

echo "[rmf-patrol] Dispatching opposing RMF patrols: ${ROBOT_0}→${ROBOT_0_DEST}, ${ROBOT_1}→${ROBOT_1_DEST}"

exec python3 /opt/rmf/scripts/dispatch-rmf-patrol.py --ros-args \
  -p use_sim_time:=true \
  -p robot_0:="${ROBOT_0}" \
  -p robot_1:="${ROBOT_1}" \
  -p fleet_name:="${FLEET_NAME}" \
  -p robot_0_dest:="${ROBOT_0_DEST}" \
  -p robot_1_dest:="${ROBOT_1_DEST}"
