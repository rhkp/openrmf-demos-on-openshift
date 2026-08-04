#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

ZENOH_ROUTER_ENDPOINT="${ZENOH_ROUTER_ENDPOINT:?ZENOH_ROUTER_ENDPOINT must be set}"

export ZENOH_ROUTER_CONFIG_OVERRIDE="connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];scouting/multicast/enabled=false"

echo "[yield-controller] Starting local Zenoh session daemon..."
ros2 run rmw_zenoh_cpp rmw_zenohd &
ZENOHD_PID=$!

cleanup() {
  echo "[yield-controller] Cleaning up zenoh daemon..."
  kill ${ZENOHD_PID} 2>/dev/null || true
}
trap cleanup EXIT

sleep 8

export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"tcp/localhost:7447\"];scouting/multicast/enabled=false"

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
