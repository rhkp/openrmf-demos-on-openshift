#!/usr/bin/env bash
# Wait until a ROS 2 service appears (requires ros-env to be sourced).
set -euo pipefail

SERVICE="${1:?Usage: wait-for-service.sh <service> [timeout_seconds]}"
TIMEOUT="${2:-600}"
INTERVAL="${WAIT_INTERVAL:-5}"

echo "[wait] Waiting for service ${SERVICE} (timeout ${TIMEOUT}s)..."
elapsed=0
until ros2 service list 2>/dev/null | grep -Fxq "${SERVICE}"; do
  if (( elapsed >= TIMEOUT )); then
    echo "[wait] Timed out waiting for ${SERVICE}" >&2
    exit 1
  fi
  sleep "${INTERVAL}"
  elapsed=$((elapsed + INTERVAL))
done
echo "[wait] Service ${SERVICE} is available."
