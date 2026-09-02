#!/usr/bin/env bash
set -euo pipefail

source /opt/rmf/scripts/ros-env.sh

# VNC + world-only for robot-as-pod mode with GPU sensor visualization
# gz-sim runs headless (no GUI) with DISPLAY unset so ogre2 uses EGL+NVIDIA GPU
# for gpu_lidar render-to-texture. RViz2 provides SLAM/lidar visualization on VNC.
DISPLAY_NUM="${DISPLAY:-:99}"
export RMF_VNC_PORT="${RMF_VNC_PORT:-5900}"
export RMF_VNC_WIDTH="${RMF_VNC_WIDTH:-1280}"
export RMF_VNC_HEIGHT="${RMF_VNC_HEIGHT:-720}"

SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"

echo "[simulation-world] Starting Xvfb on ${DISPLAY_NUM} (${RMF_VNC_WIDTH}x${RMF_VNC_HEIGHT}x24)..."
# Force mesa for Xvfb — NVIDIA EGL crashes the software X server
LIBGL_ALWAYS_SOFTWARE=1 __EGL_VENDOR_LIBRARY_FILENAMES="" \
  Xvfb "${DISPLAY_NUM}" -screen 0 "${RMF_VNC_WIDTH}x${RMF_VNC_HEIGHT}x24" +extension GLX &
XVFB_PID=$!

sleep 3

echo "[simulation-world] Starting x11vnc on port ${RMF_VNC_PORT}..."
x11vnc -display "${DISPLAY_NUM}" -rfbport "${RMF_VNC_PORT}" -shared -forever -nopw &
X11VNC_PID=$!

# Plain `kill` (SIGTERM) on a failed retry attempt is not enough — confirmed
# by a real failure: an rclpy-based process (traffic schedule or fleet
# adapter) that's still deep in native (rclcpp/zenoh) initialization when
# SIGTERM arrives can go a long time without actually dying, because
# Python's signal handling only runs between bytecode instructions on the
# main thread and won't interrupt a blocking C-extension call. The retry
# loops below don't wait to confirm the old process is gone before
# starting a new one, so the old attempt can still be alive when the new
# one launches — both then race to register the exact same ROS node name
# (e.g. `tinyRobot_fleet_adapter`), and whichever finishes second crashes
# with `AssertionError: Unable to initialize fleet adapter` even though
# the schedule node it complains about is actually up and healthy. Directly
# observed on real hardware: `ps` showing two live fleet_adapter processes
# at once, tens of seconds after the first one was supposedly killed.
# SIGKILL can't be caught or deferred, so use it here, then actually poll
# for the pid to disappear instead of assuming the signal was instant.
kill_and_confirm_dead() {
  local pid="$1" desc="$2"
  kill -9 "${pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  echo "[simulation-world] WARNING: ${desc} (pid ${pid}) still alive 10s after SIGKILL" >&2
}

cleanup() {
  echo "[simulation-world] Cleaning up..."
  kill ${FLEET_PID:-} 2>/dev/null || true
  kill ${FLEET_MGR_PID:-} 2>/dev/null || true
  kill ${GZ_GUI_PID:-} 2>/dev/null || true
  kill ${GT_ODOM_PID:-} 2>/dev/null || true
  kill ${TRAFFIC_SCHED_PID:-} 2>/dev/null || true
  kill ${GLOBAL_TF_PID:-} 2>/dev/null || true
  kill ${MAP_MERGE_PID:-} 2>/dev/null || true
  kill ${NAV_GRAPH_VIZ_PID:-} 2>/dev/null || true
  kill ${RVIZ_PID:-} 2>/dev/null || true
  kill ${OPENBOX_PID:-} 2>/dev/null || true
  kill ${X11VNC_PID} 2>/dev/null || true
  kill ${XVFB_PID} 2>/dev/null || true
  kill ${ZENOHD_PID:-} 2>/dev/null || true
}
trap cleanup EXIT

sleep 2

# Configure openbox with visible window decorations (title bar + min/max/close buttons)
mkdir -p "${HOME}/.config/openbox"
cat > "${HOME}/.config/openbox/rc.xml" << 'OBCONF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme><name>Clearlooks</name><titleLayout>NLIMC</titleLayout>
    <font place="ActiveWindow"><name>sans</name><size>10</size><weight>Bold</weight></font>
    <font place="InactiveWindow"><name>sans</name><size>9</size><weight>Normal</weight></font>
  </theme>
  <desktops><number>1</number></desktops>
  <resize><drawContents>yes</drawContents></resize>
  <applications>
    <application class="*"><decor>yes</decor></application>
  </applications>
</openbox_config>
OBCONF

echo "[simulation-world] Starting openbox window manager..."
DISPLAY="${DISPLAY_NUM}" openbox &
OPENBOX_PID=$!

# Start local Zenoh daemon connected to central router for cross-pod topic discovery
if [ -n "${ZENOH_ROUTER_ENDPOINT:-}" ]; then
  echo "[simulation-world] Starting local Zenoh daemon (peering with ${ZENOH_ROUTER_ENDPOINT})..."
  export ZENOH_ROUTER_CONFIG_OVERRIDE="connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];scouting/multicast/enabled=false"
  ros2 run rmw_zenoh_cpp rmw_zenohd &
  ZENOHD_PID=$!
  sleep 8
  export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"tcp/localhost:7447\"];scouting/multicast/enabled=false"
fi

echo "[simulation-world] Launching collision-test world HEADLESS (EGL+GPU rendering)..."

# Unset DISPLAY so ogre2 uses EGL (NVIDIA GPU) instead of GLX (Xvfb software mesa).
# This is critical for gpu_lidar render-to-texture to produce scan data.
env -u DISPLAY ros2 launch /opt/rmf/demos/common/launch/collision_test_world_only.launch.xml \
  use_sim_time:=true \
  headless:=1 &
SIM_PID=$!

# Wait for simulation to start
sleep 15

# Gazebo GUI client: connects to the headless server for 3D robot visualization.
# Uses mesa software rendering on Xvfb (the server's EGL+GPU sensor rendering is unaffected).
echo "[simulation-world] Starting Gazebo GUI on VNC display..."
DISPLAY="${DISPLAY_NUM}" LIBGL_ALWAYS_SOFTWARE=1 __EGL_VENDOR_LIBRARY_FILENAMES="" \
  gz sim -g --force-version 8 &
GZ_GUI_PID=$!

# Ground-truth odometry: reads Gazebo world poses via gz-transport subprocess
echo "[simulation-world] Starting ground-truth odom publisher..."
python3 /opt/rmf/scripts/ground_truth_odom.py --ros-args -p use_sim_time:=true \
  -p gz_world_name:=collision_test &
GT_ODOM_PID=$!

# RMF traffic schedule: central database for trajectory conflict detection
# and multi-robot negotiation. Fleet adapters in robot pods register
# trajectories here; conflicts trigger automatic rerouting/holding.
#
# Started this close to the local Zenoh daemon's own startup, its rmw_zenoh_cpp
# session can fail its one-time graph registration (a race with the daemon's
# bridge-to-router still stabilizing, seemingly worse under the CPU pressure of
# Gazebo/RViz/4x Nav2 all cold-starting at once) — the process stays alive and
# looks healthy (`kill -0` succeeds) but its services never appear in the ROS
# graph, forever, with no automatic recovery. A process-liveness check can't
# catch this; verify `/rmf_traffic/register_participant` actually shows up in
# `ros2 service list`, and restart the node if it doesn't.
#
# 3 attempts x 30s wasn't a big enough budget — confirmed by a real failure
# (twice in a row, on real GPU hardware) where all 3 attempts exhausted
# under cold-start CPU pressure and the loop just fell through silently,
# leaving NO traffic schedule node running for the rest of the container's
# life. That's what actually caused the fleet adapter's crash downstream:
# it initializes fine (registers as a node, passes the `kill -0` + `ros2
# node list` check in its own retry loop below) but only discovers ~45s
# later that there's no real schedule to talk to, and hard-crashes
# (`AssertionError: Unable to initialize fleet adapter`) with nothing left
# to restart it — a second, worse instance of the exact false-positive
# problem described above, this time undetectable by *this* node's own
# liveness check since the crash happens in a completely different
# process. 6x45s (vs fleet adapter's own 8x20s) gives strictly more
# cold-start headroom than what was observed to eventually succeed by
# hand. If even that's exhausted, don't silently continue into a
# guaranteed-broken fleet adapter — exit non-zero so systemd's
# Restart=always on rmf-simulation.service gets a real do-over instead.
echo "[simulation-world] Starting RMF traffic schedule node..."
traffic_schedule_ok=0
for attempt in 1 2 3 4 5 6; do
  echo "[simulation-world] Traffic schedule attempt ${attempt}/6..."
  ros2 run rmf_traffic_ros2 rmf_traffic_schedule --ros-args \
    -p use_sim_time:=true &
  TRAFFIC_SCHED_PID=$!
  if /opt/rmf/scripts/wait-for-service.sh /rmf_traffic/register_participant 45; then
    echo "[simulation-world] Traffic schedule registered (pid ${TRAFFIC_SCHED_PID})"
    traffic_schedule_ok=1
    break
  fi
  echo "[simulation-world] Traffic schedule did not register in time, restarting..."
  kill_and_confirm_dead "${TRAFFIC_SCHED_PID}" "traffic schedule"
  sleep 5
done
if [ "${traffic_schedule_ok}" -ne 1 ]; then
  echo "[simulation-world] FATAL: traffic schedule never registered after 6 attempts — exiting so the container restarts cleanly instead of running with a permanently-broken fleet adapter." >&2
  exit 1
fi

# Global TF publisher: publishes robot TF on global /tf for RViz
# (robot pods publish on namespaced /{robot}/tf for Nav2/SLAM)
echo "[simulation-world] Starting global TF publisher for RViz..."
python3 /opt/rmf/scripts/global_tf_publisher.py --ros-args -p use_sim_time:=true &
GLOBAL_TF_PID=$!

# Map merge: stitches each robot's independent slam_toolbox map into one
# occupancy grid (visualization-only, using the same world->{robot}/map
# transforms global_tf_publisher.py publishes above).
echo "[simulation-world] Starting map merge node..."
python3 /opt/rmf/scripts/map_merge_node.py --ros-args -p use_sim_time:=true &
MAP_MERGE_PID=$!

echo "[simulation-world] Starting nav graph visualizer..."
python3 /opt/rmf/scripts/nav_graph_visualizer.py --ros-args -p use_sim_time:=true &
NAV_GRAPH_VIZ_PID=$!

echo "[simulation-world] Starting RViz2 for SLAM/lidar visualization..."
DISPLAY="${DISPLAY_NUM}" rviz2 -d /opt/rmf/config/slam_rviz.rviz --ros-args -p use_sim_time:=true &
RVIZ_PID=$!

# Fleet manager: single instance managing ALL robots (HTTP bridge to Nav2 goals)
FLEET_ROBOTS="${FLEET_ROBOTS:-tinyRobot1,tinyRobot2,tinyRobot3,tinyRobot4}"
echo "[simulation-world] Starting fleet manager for robots: ${FLEET_ROBOTS}..."
ROBOT_NAMES="${FLEET_ROBOTS}" python3 /opt/rmf/scripts/fleet_manager.py \
  --ros-args -p use_sim_time:=true &
FLEET_MGR_PID=$!

# Fleet adapter: single instance with FULL config — coordinates all robots
# through rmf_traffic_schedule for proper intra-fleet negotiation
FLEET_CONFIG="/opt/rmf/config/collision_test_fleet_config.yaml"
NAV_GRAPH="/opt/rmf/config/collision_test_nav_graph.yaml"

# Traffic schedule registration is already confirmed by the retry loop above;
# this remaining wait is purely for the robot pods' own Nav2 stacks to finish
# discovery (a separate, legitimate startup cost in different pods we don't
# have a single readiness signal for here).
echo "[simulation-world] Waiting 15s for Nav2 discovery in robot pods..."
sleep 15

echo "[simulation-world] Starting fleet adapter (all robots, single instance)..."
fleet_adapter_ok=0
for attempt in 1 2 3 4 5 6 7 8; do
  echo "[simulation-world] Fleet adapter attempt ${attempt}/8..."
  ros2 run rmf_demos_fleet_adapter fleet_adapter \
    -c "${FLEET_CONFIG}" -n "${NAV_GRAPH}" -sim \
    --ros-args -p use_sim_time:=true -p server_uri:="${SERVER_URI}" &
  FLEET_PID=$!
  sleep 20
  # `kill -0` only proves the process didn't crash — it can't catch the same
  # zenoh graph-registration race described above for the traffic schedule
  # node, which leaves the fleet adapter alive and logging but invisible to
  # `ros2 node list` and never actually consuming task requests. Confirm it
  # actually joined the graph before accepting this attempt as successful.
  if kill -0 ${FLEET_PID} 2>/dev/null \
      && ros2 node list 2>/dev/null | grep -q '_fleet_adapter$'; then
    echo "[simulation-world] Fleet adapter running and registered (pid ${FLEET_PID})"
    fleet_adapter_ok=1
    break
  fi
  echo "[simulation-world] Fleet adapter exited or failed to register, retrying in 15s..."
  kill_and_confirm_dead "${FLEET_PID}" "fleet adapter"
  sleep 15
done
if [ "${fleet_adapter_ok}" -ne 1 ]; then
  echo "[simulation-world] FATAL: fleet adapter never registered after 8 attempts — exiting so the container restarts cleanly instead of running with no fleet adapter." >&2
  exit 1
fi

wait ${SIM_PID}
