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

# Create a per-robot fleet config by filtering the upstream config to only
# include this robot. Each robot pod runs its own fleet adapter instance.
ORIGINAL_CONFIG="/opt/rmf/config/collision_test_fleet_config.yaml"
NAV_GRAPH="/opt/rmf/config/collision_test_nav_graph.yaml"
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
# Filter to single robot
config['rmf_fleet']['robots'] = {robot_name: robots[robot_name]}

# Keep bidding enabled so robots participate in RMF task dispatch
# and traffic schedule negotiation for collision avoidance
config['rmf_fleet']['task_capabilities'] = {
    'loop': True,
    'delivery': True
}

with open('${FILTERED_CONFIG}', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)
print(f'Wrote non-bidding config for [{robot_name}] to ${FILTERED_CONFIG}')
print('Robot bidding enabled for RMF traffic schedule collision avoidance')
"

# Configure the local Zenoh session daemon (rmw_zenohd) to peer with the
# central Zenoh router for cross-pod topic discovery.
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

# Point ROS nodes to the LOCAL session daemon, not the central router directly.
export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"tcp/localhost:7447\"];scouting/multicast/enabled=false"

echo "[${ROBOT_NAME}] Waiting for world simulation topics..."
/opt/rmf/scripts/wait-for-world.sh 300

echo "[${ROBOT_NAME}] World ready — launching nav2 + fleet adapter for robot [${ROBOT_NAME}]..."

# Generate per-robot Nav2 params: replace ROBOT_PLACEHOLDER and wrap under namespace
# (nav2_bringup's navigation_launch.py uses RewrittenYaml with root_key=namespace)
NAV2_PARAMS="/tmp/${ROBOT_NAME}_nav2_params.yaml"
SLAM_PARAMS="/tmp/${ROBOT_NAME}_slam_params.yaml"
sed "s/ROBOT_PLACEHOLDER/${ROBOT_NAME}/g" /opt/rmf/config/nav2_params.yaml > "${NAV2_PARAMS}"
sed "s/ROBOT_PLACEHOLDER/${ROBOT_NAME}/g" /opt/rmf/config/slam_toolbox_params.yaml > "${SLAM_PARAMS}"
echo "[${ROBOT_NAME}] Generated per-robot params: ${NAV2_PARAMS}, ${SLAM_PARAMS}"

# Start TF publisher — publishes to namespaced /{robot}/tf topics
# (nav2_bringup remaps /tf → tf which resolves to /{namespace}/tf)
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

# Start fleet manager (FastAPI bridge: fleet adapter HTTP → Nav2 goals)
echo "[${ROBOT_NAME}] Starting fleet manager (HTTP → Nav2 bridge)..."
ROBOT_NAME="${ROBOT_NAME}" python3 /opt/rmf/scripts/fleet_manager.py \
  --ros-args -p use_sim_time:=true &
FLEET_MGR_PID=$!

# Update cleanup function
cleanup() {
  echo "[${ROBOT_NAME}] Cleaning up tf_publisher, nav2, fleet_manager, and zenoh daemon..."
  kill ${TF_PUB_PID} 2>/dev/null || true
  kill ${NAV2_PID} 2>/dev/null || true
  kill ${FLEET_MGR_PID} 2>/dev/null || true
  kill ${ZENOHD_PID} 2>/dev/null || true
}
trap cleanup EXIT

# Launch fleet adapter directly (NOT the upstream launch file, which also starts
# its own fleet_manager that would conflict with ours on port 22011).
for attempt in 1 2 3 4 5; do
  echo "[${ROBOT_NAME}] Fleet adapter attempt ${attempt}/5..."
  ros2 run rmf_demos_fleet_adapter fleet_adapter \
    -- -c "${FILTERED_CONFIG}" -n "${NAV_GRAPH}" -sim \
    --ros-args -p use_sim_time:=true -p server_uri:="${SERVER_URI}" &
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
