#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

ROBOT_NAME="${ROBOT_NAME:?ROBOT_NAME env var must be set}"

echo "[${ROBOT_NAME}] Launching Nav2/SLAM robot pod..."
echo "[${ROBOT_NAME}] Zenoh router: ${ZENOH_ROUTER_ENDPOINT}"

# Configure the local Zenoh session daemon (rmw_zenohd) to peer with the
# central Zenoh router for cross-pod topic discovery.
export ZENOH_ROUTER_CONFIG_OVERRIDE="connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];scouting/multicast/enabled=false"

echo "[${ROBOT_NAME}] Starting local Zenoh session daemon (peering with central router)..."
ros2 run rmw_zenoh_cpp rmw_zenohd &
ZENOHD_PID=$!

cleanup() {
  echo "[${ROBOT_NAME}] Cleaning up..."
  kill ${TF_PUB_PID:-} 2>/dev/null || true
  kill ${NAV2_PID:-} 2>/dev/null || true
  kill ${ZENOHD_PID} 2>/dev/null || true
}
trap cleanup EXIT

sleep 8

# Point ROS nodes to the LOCAL session daemon, not the central router directly.
export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"tcp/localhost:7447\"];scouting/multicast/enabled=false"

echo "[${ROBOT_NAME}] Waiting for world simulation topics..."
/opt/rmf/scripts/wait-for-world.sh 300

echo "[${ROBOT_NAME}] World ready — launching Nav2/SLAM stack..."

# Generate per-robot Nav2 params
NAV2_PARAMS="/tmp/${ROBOT_NAME}_nav2_params.yaml"
SLAM_PARAMS="/tmp/${ROBOT_NAME}_slam_params.yaml"
sed "s/ROBOT_PLACEHOLDER/${ROBOT_NAME}/g" /opt/rmf/config/nav2_params.yaml > "${NAV2_PARAMS}"
sed "s/ROBOT_PLACEHOLDER/${ROBOT_NAME}/g" /opt/rmf/config/slam_toolbox_params.yaml > "${SLAM_PARAMS}"

# Safety net: ensure collision params are tuned even if old image is cached
sed -i '/PolygonStop:/,/enabled:/{s/min_points: 3/min_points: 1/}' "${NAV2_PARAMS}"
sed -i '/PolygonStop:/,/enabled:/{s/radius: 0.4/radius: 0.5/}' "${NAV2_PARAMS}"
sed -i '/PolygonSlow:/,/enabled:/{s/min_points: 3/min_points: 2/}' "${NAV2_PARAMS}"

echo "[${ROBOT_NAME}] Generated per-robot params: ${NAV2_PARAMS}, ${SLAM_PARAMS}"

# TF publisher — publishes to namespaced /{robot}/tf topics
echo "[${ROBOT_NAME}] Starting Nav2 TF publisher..."
python3 /opt/rmf/scripts/nav2_tf_publisher.py --ros-args \
  -p robot_name:="${ROBOT_NAME}" \
  -p use_sim_time:=true \
  --remap odom:=/"${ROBOT_NAME}"/odom \
  --remap /tf:=/"${ROBOT_NAME}"/tf \
  --remap /tf_static:=/"${ROBOT_NAME}"/tf_static &
TF_PUB_PID=$!

sleep 2

# Nav2 navigation stack with SLAM
echo "[${ROBOT_NAME}] Starting Nav2 navigation stack..."
ros2 launch /opt/rmf/demos/common/launch/nav2_robot.launch.xml \
  robot_name:="${ROBOT_NAME}" \
  use_sim_time:=true \
  nav2_params_file:="${NAV2_PARAMS}" \
  slam_params_file:="${SLAM_PARAMS}" &
NAV2_PID=$!

echo "[${ROBOT_NAME}] Nav2/SLAM running. Fleet adapter runs in sim pod."
wait ${NAV2_PID}
