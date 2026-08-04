#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

ROBOT_0="${ROBOT_0:-tinyRobot1}"
ROBOT_1="${ROBOT_1:-tinyRobot2}"
ROBOT_2="${ROBOT_2:-tinyRobot3}"
ROBOT_3="${ROBOT_3:-tinyRobot4}"
FLEET_NAME="${FLEET_NAME:-tinyRobot}"
ROBOT_0_DEST="${ROBOT_0_DEST:-wp_east}"
ROBOT_1_DEST="${ROBOT_1_DEST:-wp_west}"
ROBOT_2_DEST="${ROBOT_2_DEST:-wp_north}"
ROBOT_3_DEST="${ROBOT_3_DEST:-wp_south}"
READY_WAIT_SECONDS="${READY_WAIT_SECONDS:-90}"

echo "[rmf-patrol] Waiting ${READY_WAIT_SECONDS}s for fleet adapters + traffic schedule..."
sleep "${READY_WAIT_SECONDS}"

echo "[rmf-patrol] Dispatching cross patrols:"
echo "  ${ROBOT_0}→${ROBOT_0_DEST}, ${ROBOT_1}→${ROBOT_1_DEST}"
echo "  ${ROBOT_2}→${ROBOT_2_DEST}, ${ROBOT_3}→${ROBOT_3_DEST}"

exec python3 /opt/rmf/scripts/dispatch-rmf-patrol.py --ros-args \
  -p use_sim_time:=true \
  -p robot_0:="${ROBOT_0}" \
  -p robot_1:="${ROBOT_1}" \
  -p robot_2:="${ROBOT_2}" \
  -p robot_3:="${ROBOT_3}" \
  -p fleet_name:="${FLEET_NAME}" \
  -p robot_0_dest:="${ROBOT_0_DEST}" \
  -p robot_1_dest:="${ROBOT_1_DEST}" \
  -p robot_2_dest:="${ROBOT_2_DEST}" \
  -p robot_3_dest:="${ROBOT_3_DEST}"
