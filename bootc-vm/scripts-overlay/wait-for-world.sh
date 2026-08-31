#!/usr/bin/env bash
# Wait for the Gazebo world simulation to be ready before starting robot adapters
set -euo pipefail

TIMEOUT="${1:-300}"
INTERVAL="${WAIT_INTERVAL:-10}"

echo "[wait-world] Waiting for Gazebo world simulation (timeout ${TIMEOUT}s)..."
elapsed=0

while true; do
  if (( elapsed >= TIMEOUT )); then
    echo "[wait-world] Timed out waiting for Gazebo world simulation" >&2
    exit 1
  fi

  # Single ros2 topic list call with generous timeout for Zenoh discovery,
  # then check all required topics at once from the captured output
  TOPIC_LIST=$(timeout 30 ros2 topic list 2>/dev/null || true)

  if echo "${TOPIC_LIST}" | grep -Fxq "/clock" && \
     echo "${TOPIC_LIST}" | grep -Fxq "/tf" && \
     echo "${TOPIC_LIST}" | grep -Fxq "/tf_static"; then
    echo "[wait-world] Gazebo world simulation is ready."
    break
  fi

  echo "[wait-world] Still waiting for world simulation... (${elapsed}s elapsed)"
  sleep "${INTERVAL}"
  elapsed=$((elapsed + INTERVAL))
done
