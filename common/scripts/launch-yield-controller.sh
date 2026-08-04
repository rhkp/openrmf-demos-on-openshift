#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

# ros-env.sh already sets ZENOH_CONFIG_OVERRIDE to connect to the central Zenoh router.
# No local daemon needed — same pattern as fleet-monitor and task-dispatch.

YIELDING_GOAL_X="${YIELDING_GOAL_X:-0.0}"
YIELDING_GOAL_Y="${YIELDING_GOAL_Y:-0.0}"
YIELDING_GOAL_YAW="${YIELDING_GOAL_YAW:-0.0}"

echo "[yield-controller] Starting priority-based yield controller..."
echo "[yield-controller] Yielding robot goal: (${YIELDING_GOAL_X}, ${YIELDING_GOAL_Y}, ${YIELDING_GOAL_YAW})"

exec python3 /opt/rmf/scripts/robot_yield_controller.py --ros-args \
  -p use_sim_time:=true \
  -p priority_robot:=tinyRobot_0 \
  -p yielding_robot:=tinyRobot_1 \
  -p detection_distance:=3.0 \
  -p heading_tolerance:=0.6 \
  -p backup_distance:=0.5 \
  -p wait_duration:=5.0 \
  -p resume_distance:=2.0 \
  -p yielding_goal_x:="${YIELDING_GOAL_X}" \
  -p yielding_goal_y:="${YIELDING_GOAL_Y}" \
  -p yielding_goal_yaw:="${YIELDING_GOAL_YAW}"
