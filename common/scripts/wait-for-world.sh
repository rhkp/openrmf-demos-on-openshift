#!/usr/bin/env bash
# Wait for the Gazebo world simulation to be ready before starting robot adapters
set -euo pipefail

TIMEOUT="${1:-300}"
INTERVAL="${WAIT_INTERVAL:-5}"

echo "[wait-world] Waiting for Gazebo world simulation (timeout ${TIMEOUT}s)..."
elapsed=0

# Wait for essential world topics to be available
REQUIRED_TOPICS=(
  "/clock"
  "/tf"
  "/tf_static"
)

while true; do
  if (( elapsed >= TIMEOUT )); then
    echo "[wait-world] Timed out waiting for Gazebo world simulation" >&2
    exit 1
  fi

  # Check if all required topics are available
  all_topics_ready=true
  for topic in "${REQUIRED_TOPICS[@]}"; do
    if ! ros2 topic list 2>/dev/null | grep -Fxq "${topic}"; then
      all_topics_ready=false
      break
    fi
  done

  if [[ "${all_topics_ready}" == "true" ]]; then
    echo "[wait-world] Gazebo world simulation is ready."
    break
  fi

  echo "[wait-world] Still waiting for world simulation... (${elapsed}s elapsed)"
  sleep "${INTERVAL}"
  elapsed=$((elapsed + INTERVAL))
done