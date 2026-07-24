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
ORIGINAL_CONFIG="$(ros2 pkg prefix rmf_demos)/share/rmf_demos/config/office/tinyRobot_config.yaml"
NAV_GRAPH="$(ros2 pkg prefix rmf_demos_maps)/share/rmf_demos_maps/maps/office/nav_graphs/0.yaml"
FILTERED_CONFIG="/tmp/${ROBOT_NAME}_config.yaml"

echo "[${ROBOT_NAME}] Filtering fleet config to robot [${ROBOT_NAME}]..."
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
with open('${FILTERED_CONFIG}', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)
print(f'Wrote per-robot config for [{robot_name}] to ${FILTERED_CONFIG}')
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

echo "[${ROBOT_NAME}] World ready — launching fleet adapter for robot [${ROBOT_NAME}]..."

# Find upstream fleet_adapter launch file and invoke with per-robot config
FLEET_ADAPTER_LAUNCH="$(ros2 pkg prefix rmf_demos_fleet_adapter)/share/rmf_demos_fleet_adapter/launch/fleet_adapter.launch.xml"

exec ros2 launch "${FLEET_ADAPTER_LAUNCH}" \
  use_sim_time:=true \
  "nav_graph_file:=${NAV_GRAPH}" \
  "config_file:=${FILTERED_CONFIG}" \
  "server_uri:=${SERVER_URI}"
