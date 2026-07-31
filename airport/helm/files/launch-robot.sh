#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

ROBOT_NAME="${ROBOT_NAME:?ROBOT_NAME env var must be set}"
SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"

echo "[${ROBOT_NAME}] Launching individual robot adapter pod..."
echo "[${ROBOT_NAME}] RMF server_uri=${SERVER_URI}"
echo "[${ROBOT_NAME}] Zenoh router: ${ZENOH_ROUTER_ENDPOINT}"

# Airport terminal fleet config
ORIGINAL_CONFIG="$(ros2 pkg prefix rmf_demos)/share/rmf_demos/config/airport_terminal/tinyRobot_config.yaml"
NAV_GRAPH="$(ros2 pkg prefix rmf_demos_maps)/share/rmf_demos_maps/maps/airport_terminal/nav_graphs/0.yaml"
FILTERED_CONFIG="/tmp/${ROBOT_NAME}_config.yaml"

echo "[${ROBOT_NAME}] Filtering fleet config to robot [${ROBOT_NAME}] with bidding enabled..."
python3 -c "
import yaml, sys
with open('${ORIGINAL_CONFIG}') as f:
    config = yaml.safe_load(f)
robot_name = '${ROBOT_NAME}'
robots = config.get('rmf_fleet', {}).get('robots', {})
if robot_name not in robots:
    print(f'ERROR: robot [{robot_name}] not found in config. Available: {list(robots.keys())}', file=sys.stderr)
    sys.exit(1)
config['rmf_fleet']['robots'] = {robot_name: robots[robot_name]}

config['rmf_fleet']['task_capabilities'] = {
    'loop': True,
    'delivery': True
}

with open('${FILTERED_CONFIG}', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)
print(f'Wrote config for [{robot_name}] to ${FILTERED_CONFIG}')
"

# Configure Zenoh peering
export ZENOH_ROUTER_CONFIG_OVERRIDE="connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];scouting/multicast/enabled=false"

echo "[${ROBOT_NAME}] Starting local Zenoh session daemon (peering with central router)..."
ros2 run rmw_zenoh_cpp rmw_zenohd &
ZENOHD_PID=$!

cleanup() {
  echo "[${ROBOT_NAME}] Cleaning up zenoh daemon..."
  kill ${ZENOHD_PID} 2>/dev/null || true
}
trap cleanup EXIT

sleep 8

export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"tcp/localhost:7447\"];scouting/multicast/enabled=false"

echo "[${ROBOT_NAME}] Waiting for world simulation topics..."
/opt/rmf/scripts/wait-for-world.sh 300

echo "[${ROBOT_NAME}] World ready — launching nav2 + fleet adapter for robot [${ROBOT_NAME}]..."

# Generate per-robot Nav2 params
NAV2_PARAMS="/tmp/${ROBOT_NAME}_nav2_params.yaml"
SLAM_PARAMS="/tmp/${ROBOT_NAME}_slam_params.yaml"
sed "s/ROBOT_PLACEHOLDER/${ROBOT_NAME}/g" /opt/rmf/config/nav2_params.yaml > "${NAV2_PARAMS}"
sed "s/ROBOT_PLACEHOLDER/${ROBOT_NAME}/g" /opt/rmf/config/slam_toolbox_params.yaml > "${SLAM_PARAMS}"
echo "[${ROBOT_NAME}] Generated per-robot params: ${NAV2_PARAMS}, ${SLAM_PARAMS}"

# Start TF publisher
echo "[${ROBOT_NAME}] Starting Nav2 TF publisher..."
python3 /opt/rmf/scripts/nav2_tf_publisher.py --ros-args \
  -p robot_name:="${ROBOT_NAME}" \
  -p use_sim_time:=true \
  --remap odom:=/"${ROBOT_NAME}"/odom \
  --remap /tf:=/"${ROBOT_NAME}"/tf \
  --remap /tf_static:=/"${ROBOT_NAME}"/tf_static &
TF_PUB_PID=$!

sleep 2

# Launch Nav2 navigation stack with SLAM
echo "[${ROBOT_NAME}] Starting Nav2 navigation stack..."
ros2 launch /opt/rmf/demos/common/launch/nav2_robot.launch.xml \
  robot_name:="${ROBOT_NAME}" \
  use_sim_time:=true \
  nav2_params_file:="${NAV2_PARAMS}" \
  slam_params_file:="${SLAM_PARAMS}" &
NAV2_PID=$!

# Start RMF-Nav2 bridge
echo "[${ROBOT_NAME}] Starting RMF-Nav2 bridge..."
python3 /opt/rmf/scripts/rmf_nav2_bridge.py --ros-args \
  -p robot_name:="${ROBOT_NAME}" \
  -p fleet_name:="tinyRobot" &
BRIDGE_PID=$!

# Start autonomous frontier exploration for SLAM mapping using explore_lite
echo "[${ROBOT_NAME}] Starting explore_lite..."
EXPLORE_PARAMS="/tmp/${ROBOT_NAME}_explore_params.yaml"
sed "s/ROBOT_PLACEHOLDER/${ROBOT_NAME}/g" /opt/rmf/config/explore_params.yaml > "${EXPLORE_PARAMS}"

ros2 run explore_lite explore --ros-args \
  --params-file "${EXPLORE_PARAMS}" \
  -p use_sim_time:=true \
  -r __ns:=/"${ROBOT_NAME}" \
  -r /tf:=tf \
  -r /tf_static:=tf_static &
EXPLORE_PID=$!

cleanup() {
  echo "[${ROBOT_NAME}] Cleaning up tf_publisher, nav2, bridge, explore, and zenoh daemon..."
  kill ${TF_PUB_PID} 2>/dev/null || true
  kill ${NAV2_PID} 2>/dev/null || true
  kill ${BRIDGE_PID} 2>/dev/null || true
  kill ${EXPLORE_PID} 2>/dev/null || true
  kill ${ZENOHD_PID} 2>/dev/null || true
}
trap cleanup EXIT

# Find upstream fleet_adapter launch file
FLEET_ADAPTER_LAUNCH="$(ros2 pkg prefix rmf_demos_fleet_adapter)/share/rmf_demos_fleet_adapter/launch/fleet_adapter.launch.xml"

# Launch fleet adapter with retry
for attempt in 1 2 3 4 5; do
  echo "[${ROBOT_NAME}] Fleet adapter attempt ${attempt}/5..."
  ros2 launch "${FLEET_ADAPTER_LAUNCH}" \
    use_sim_time:=true \
    "nav_graph_file:=${NAV_GRAPH}" \
    "config_file:=${FILTERED_CONFIG}" \
    "server_uri:=${SERVER_URI}" &
  FLEET_PID=$!
  sleep 15
  if kill -0 ${FLEET_PID} 2>/dev/null; then
    echo "[${ROBOT_NAME}] Fleet adapter running (pid ${FLEET_PID})"
    wait ${FLEET_PID}
    break
  fi
  echo "[${ROBOT_NAME}] Fleet adapter exited, retrying in 10s..."
  sleep 10
done

echo "[${ROBOT_NAME}] Fleet adapter exited after all attempts"
wait
