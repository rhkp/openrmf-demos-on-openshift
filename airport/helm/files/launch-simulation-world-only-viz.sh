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

# Read the gz-sim world element name (extracted at Docker build time)
GZ_WORLD_NAME=$(cat /opt/rmf/config/airport_terminal_gz_world_name.txt 2>/dev/null || echo "airport_terminal")

echo "[simulation-world] Starting Xvfb on ${DISPLAY_NUM} (${RMF_VNC_WIDTH}x${RMF_VNC_HEIGHT}x24)..."
LIBGL_ALWAYS_SOFTWARE=1 __EGL_VENDOR_LIBRARY_FILENAMES="" \
  Xvfb "${DISPLAY_NUM}" -screen 0 "${RMF_VNC_WIDTH}x${RMF_VNC_HEIGHT}x24" +extension GLX &
XVFB_PID=$!

echo "[simulation-world] Starting x11vnc on port ${RMF_VNC_PORT}..."
x11vnc -display "${DISPLAY_NUM}" -rfbport "${RMF_VNC_PORT}" -shared -forever -nopw &
X11VNC_PID=$!

cleanup() {
  echo "[simulation-world] Cleaning up..."
  kill ${GZ_GUI_PID:-} 2>/dev/null || true
  kill ${GT_ODOM_PID:-} 2>/dev/null || true
  kill ${GLOBAL_TF_PID:-} 2>/dev/null || true
  kill ${RVIZ_PID:-} 2>/dev/null || true
  kill ${OPENBOX_PID:-} 2>/dev/null || true
  kill ${X11VNC_PID} 2>/dev/null || true
  kill ${XVFB_PID} 2>/dev/null || true
  kill ${ZENOHD_PID:-} 2>/dev/null || true
}
trap cleanup EXIT

sleep 2

echo "[simulation-world] Starting openbox window manager..."
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
    <application title="Gazebo*">
      <position force="yes"><x>0</x><y>0</y></position>
      <size><width>640</width><height>720</height></size>
    </application>
    <application title="RViz*">
      <position force="yes"><x>640</x><y>0</y></position>
      <size><width>640</width><height>720</height></size>
    </application>
  </applications>
</openbox_config>
OBCONF
DISPLAY="${DISPLAY_NUM}" openbox &
OPENBOX_PID=$!
sleep 2

# Start local Zenoh daemon connected to central router for cross-pod topic discovery
if [ -n "${ZENOH_ROUTER_ENDPOINT:-}" ]; then
  echo "[simulation-world] Starting local Zenoh daemon (peering with ${ZENOH_ROUTER_ENDPOINT})..."
  export ZENOH_ROUTER_CONFIG_OVERRIDE="connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];scouting/multicast/enabled=false"
  ros2 run rmw_zenoh_cpp rmw_zenohd &
  ZENOHD_PID=$!
  sleep 8
  export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"tcp/localhost:7447\"];scouting/multicast/enabled=false"
fi

echo "[simulation-world] Launching airport world HEADLESS (EGL+GPU rendering)..."
echo "[simulation-world] RMF server_uri=${SERVER_URI}"
echo "[simulation-world] GZ world name=${GZ_WORLD_NAME}"

# Unset DISPLAY so ogre2 uses EGL (NVIDIA GPU) instead of GLX (Xvfb software mesa).
env -u DISPLAY ros2 launch /opt/rmf/demos/common/launch/airport_world_only.launch.xml \
  use_sim_time:=true \
  headless:=1 \
  gz_world_name:="${GZ_WORLD_NAME}" \
  "server_uri:=${SERVER_URI}" &
SIM_PID=$!

sleep 15

# Gazebo GUI client on VNC display (software rendering), left half
echo "[simulation-world] Starting Gazebo GUI on VNC display..."
DISPLAY="${DISPLAY_NUM}" LIBGL_ALWAYS_SOFTWARE=1 __EGL_VENDOR_LIBRARY_FILENAMES="" \
  gz sim -g --force-version 8 &
GZ_GUI_PID=$!

sleep 3

# Ground-truth odometry with airport robot names and world name
echo "[simulation-world] Starting ground-truth odom publisher..."
python3 /opt/rmf/scripts/ground_truth_odom.py --ros-args \
  -p use_sim_time:=true \
  -p gz_world_name:="${GZ_WORLD_NAME}" \
  -p robot_names:="['tinyRobot_0','tinyRobot_1']" &
GT_ODOM_PID=$!

# Global TF publisher with airport robot names
echo "[simulation-world] Starting global TF publisher for RViz..."
python3 /opt/rmf/scripts/global_tf_publisher.py --ros-args \
  -p use_sim_time:=true \
  -p robot_names:="['tinyRobot_0','tinyRobot_1']" &
GLOBAL_TF_PID=$!

echo "[simulation-world] Starting RViz2 for SLAM/lidar visualization..."
DISPLAY="${DISPLAY_NUM}" rviz2 -d /opt/rmf/config/airport_slam_rviz.rviz --ros-args -p use_sim_time:=true &
RVIZ_PID=$!

wait ${SIM_PID}
