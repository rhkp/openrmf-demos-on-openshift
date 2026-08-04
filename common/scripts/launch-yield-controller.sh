#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

# ros-env.sh already sets ZENOH_CONFIG_OVERRIDE to connect to the central Zenoh router.
# No local daemon needed — same pattern as fleet-monitor and task-dispatch.

PRIORITY_ROBOT="${PRIORITY_ROBOT:-tinyRobot_0}"
YIELDING_ROBOT="${YIELDING_ROBOT:-tinyRobot_1}"
YIELDING_GOAL_X="${YIELDING_GOAL_X:-3.0}"
YIELDING_GOAL_Y="${YIELDING_GOAL_Y:-0.0}"
YIELDING_GOAL_YAW="${YIELDING_GOAL_YAW:-0.0}"

echo "[yield-controller] Starting priority-based yield controller..."
echo "[yield-controller] Priority: ${PRIORITY_ROBOT}, Yielding: ${YIELDING_ROBOT}"
echo "[yield-controller] Yielding robot goal: (${YIELDING_GOAL_X}, ${YIELDING_GOAL_Y}, ${YIELDING_GOAL_YAW})"

exec python3 /opt/rmf/scripts/robot_yield_controller.py --ros-args \
  -p use_sim_time:=true \
  -p priority_robot:="${PRIORITY_ROBOT}" \
  -p yielding_robot:="${YIELDING_ROBOT}" \
  -p detection_distance:=3.0 \
  -p heading_tolerance:=0.6 \
  -p backup_distance:=1.0 \
  -p wait_duration:=8.0 \
  -p resume_distance:=2.0 \
  -p yielding_goal_x:="${YIELDING_GOAL_X}" \
  -p yielding_goal_y:="${YIELDING_GOAL_Y}" \
  -p yielding_goal_yaw:="${YIELDING_GOAL_YAW}"
