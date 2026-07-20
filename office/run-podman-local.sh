#!/usr/bin/env bash
# Run the OpenRMF office demo locally with Podman (baseline validation before OpenShift).
#
# Usage (from repo root):
#   ./office/run-podman-local.sh build          # build image (30+ min first time)
#   ./office/run-podman-local.sh start          # start sim + fleet-monitor + task-dispatch
#   ./office/run-podman-local.sh start-desktop  # same, Gazebo on host DISPLAY (xrdp)
#   ./office/run-podman-local.sh logs           # tail simulation logs
#   ./office/run-podman-local.sh patrol        # manual patrol if auto-dispatch missed
#   ./office/run-podman-local.sh stop          # stop all office demo containers
#   ./office/run-podman-local.sh status
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PODMAN="${PODMAN:-podman}"
IMAGE="${RMF_IMAGE:-openrmf-office-demo:local}"
NOVNC_IMAGE="${NOVNC_IMAGE:-openrmf-office-demo:novnc}"
ROS_VOL="${ROS_VOL:-openrmf-office-ros}"
SHM_VOL="${SHM_VOL:-openrmf-office-shm}"
NETWORK="${PODMAN_NETWORK:-host}"
LAUNCH_FILE="${RMF_LAUNCH_FILE:-office.launch.xml}"
SERVER_URI="${RMF_SERVER_URI:-ws://localhost:8000/_internal}"
WITH_RMF_WEB="${WITH_RMF_WEB:-0}"
WITH_NOVNC="${WITH_NOVNC:-0}"

SIM_NAME="rmf-office-simulation"
FLEET_NAME="rmf-office-fleet-monitor"
DISPATCH_NAME="rmf-office-task-dispatch"
API_NAME="rmf-office-api"
DASH_NAME="rmf-office-dashboard"
NOVNC_NAME="rmf-office-novnc"

common_run_flags() {
  echo --rm -d --network "${NETWORK}" \
    --shm-size=2g \
    -v "${ROS_VOL}:/opt/rmf/.ros" \
    -e ROS_LOCALHOST_ONLY=1 \
    -e RMF_LAUNCH_FILE="${LAUNCH_FILE}" \
    -e RMF_SERVER_URI="${SERVER_URI}"
}

cmd_build() {
  echo "==> Building ${IMAGE} (linux/amd64)"
  "${PODMAN}" build \
    --platform linux/amd64 \
    -f "${ROOT_DIR}/common/Dockerfile" \
    -t "${IMAGE}" \
    "${ROOT_DIR}"

  if [[ "${WITH_NOVNC}" == "1" ]]; then
    echo "==> Building ${NOVNC_IMAGE}"
    "${PODMAN}" build \
      --platform linux/amd64 \
      -f "${ROOT_DIR}/common/novnc/Dockerfile" \
      -t "${NOVNC_IMAGE}" \
      "${ROOT_DIR}/common/novnc"
  fi
}

cmd_stop() {
  for c in "${NOVNC_NAME}" "${DASH_NAME}" "${API_NAME}" "${DISPATCH_NAME}" "${FLEET_NAME}" "${SIM_NAME}"; do
    "${PODMAN}" rm -f "${c}" 2>/dev/null || true
  done
  echo "==> Stopped office demo containers"
}

cmd_start_sim() {
  local mode="${1:-headless}"
  local -a sim_cmd
  local -a extra_env=()
  local -a extra_mount=()

  case "${mode}" in
    desktop)
      if [[ -z "${DISPLAY:-}" ]]; then
        echo "DISPLAY is not set. On xrdp, run: export DISPLAY=\$(grep -m1 '^DISPLAY=' ~/.xsession-errors 2>/dev/null | cut -d= -f2)" >&2
        echo "Or: export DISPLAY=:10.0" >&2
        exit 1
      fi
      xhost +local: 2>/dev/null || true
      sim_cmd=(/opt/rmf/scripts/launch-simulation-desktop.sh)
      extra_env+=(-e "DISPLAY=${DISPLAY}")
      extra_mount+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
      ;;
    viz)
      sim_cmd=(/opt/rmf/scripts/launch-simulation-viz.sh)
      extra_env+=(-e RMF_VNC_PORT=5900 -e RMF_VNC_WIDTH=1280 -e RMF_VNC_HEIGHT=720)
      ;;
    headless|*)
      sim_cmd=(/opt/rmf/scripts/launch-simulation.sh)
      ;;
  esac

  echo "==> Starting simulation (${mode})"
  # shellcheck disable=SC2046
  "${PODMAN}" run --name "${SIM_NAME}" $(common_run_flags) \
    "${extra_env[@]}" "${extra_mount[@]}" \
    "${IMAGE}" "${sim_cmd[@]}"
}

cmd_start_sidecars() {
  echo "==> Starting fleet-monitor"
  # shellcheck disable=SC2046
  "${PODMAN}" run --name "${FLEET_NAME}" $(common_run_flags) \
    "${IMAGE}" /opt/rmf/scripts/run-fleet-monitor.sh

  echo "==> Starting task-dispatch"
  # shellcheck disable=SC2046
  "${PODMAN}" run --name "${DISPATCH_NAME}" $(common_run_flags) \
    -e READY_WAIT_SECONDS=30 \
    "${IMAGE}" /opt/rmf/demos/office/scripts/dispatch-task.sh
}

cmd_start_rmf_web() {
  echo "==> Starting RMF Web API (host network, localhost:8000)"
  "${PODMAN}" run --name "${API_NAME}" --rm -d --network host \
    -e ROS_LOCALHOST_ONLY=1 \
    -e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
    ghcr.io/open-rmf/rmf-web/api-server:jazzy-nightly \
    bash -c 'source /opt/ros/jazzy/setup.bash && exec rmf_api_server'

  echo "==> Starting RMF Web dashboard (host network, localhost:3000)"
  "${PODMAN}" run --name "${DASH_NAME}" --rm -d --network host \
    -p 3000:3000 \
    ghcr.io/open-rmf/rmf-web/demo-dashboard:jazzy-nightly
}

cmd_start_novnc() {
  echo "==> Starting noVNC sidecar (http://localhost:8080 -> VNC 5900)"
  "${PODMAN}" run --name "${NOVNC_NAME}" --rm -d --network host \
    "${NOVNC_IMAGE}" --web /opt/novnc 8080 127.0.0.1:5900
}

cmd_start() {
  local mode="${1:-headless}"
  cmd_stop
  "${PODMAN}" volume create "${ROS_VOL}" 2>/dev/null || true
  cmd_start_sim "${mode}"
  sleep 5
  cmd_start_sidecars
  if [[ "${WITH_RMF_WEB}" == "1" ]]; then
    cmd_start_rmf_web
  fi
  if [[ "${WITH_NOVNC}" == "1" ]]; then
    cmd_start_novnc
  fi
  cmd_status
  echo ""
  echo "Give simulation ~2 minutes to load Gazebo, then check logs:"
  echo "  ${PODMAN} logs -f ${SIM_NAME}"
  echo "  ${PODMAN} logs -f ${FLEET_NAME}"
  echo "  ${PODMAN} logs -f ${DISPATCH_NAME}"
}

cmd_patrol() {
  "${PODMAN}" exec "${SIM_NAME}" bash -c \
    'source /opt/rmf/scripts/ros-env.sh && ros2 run rmf_demos_tasks dispatch_patrol -p coe lounge -n 3 --use_sim_time'
}

cmd_logs() {
  local target="${1:-${SIM_NAME}}"
  "${PODMAN}" logs -f "${target}"
}

cmd_status() {
  "${PODMAN}" ps -a --filter "name=rmf-office" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
}

main() {
  local action="${1:-}"
  case "${action}" in
    build) cmd_build ;;
    stop) cmd_stop ;;
    start) cmd_start headless ;;
    start-desktop) cmd_start desktop ;;
    start-viz) WITH_NOVNC=1 cmd_start viz ;;
    start-full) WITH_RMF_WEB=1 WITH_NOVNC=1 cmd_start viz ;;
    patrol) cmd_patrol ;;
    logs) cmd_logs "${2:-${SIM_NAME}}" ;;
    status) cmd_status ;;
    *)
      sed -n '3,12p' "$0"
      exit 1
      ;;
  esac
}

main "$@"
