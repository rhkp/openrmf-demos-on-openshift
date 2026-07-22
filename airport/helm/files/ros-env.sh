#!/usr/bin/env bash
# Shared ROS 2 environment for all containers in the RMF demo pod.
# Note: avoid `set -u` — ROS setup.bash references unset vars (e.g. AMENT_TRACE_SETUP_FILES).
set -eo pipefail

# Callers may enable nounset; disable while sourcing ROS setup scripts.
set +u
source /opt/ros/jazzy/setup.bash
source "${RMF_WS}/install/setup.bash"

export RMW_IMPLEMENTATION=rmw_zenoh_cpp
export ZENOH_ROUTER_ENDPOINT="${ZENOH_ROUTER_ENDPOINT:-tcp/localhost:7447}"
export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"]"
export ROS_LOG_DIR="${ROS_LOG_DIR:-/opt/rmf/.ros/log}"
export HOME="${HOME:-/opt/rmf}"
