#!/usr/bin/env bash
# Build and push office, hotel, and airport demo images to Quay.io.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

podman_ready() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    podman ps >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

podman machine start 2>/dev/null || true
sleep 12
podman_ready || {
  echo "Podman is not available. Run: podman machine start" >&2
  exit 1
}

echo "========================================"
echo "Building office demo images"
echo "========================================"
VALUES_FILE="${ROOT_DIR}/office/helm/values.yaml" "${ROOT_DIR}/common/build-and-push.sh"

echo ""
echo "========================================"
echo "Building hotel demo images"
echo "========================================"
VALUES_FILE="${ROOT_DIR}/hotel/helm/values.yaml" "${ROOT_DIR}/common/build-and-push.sh"

echo ""
echo "========================================"
echo "Building airport demo images"
echo "========================================"
VALUES_FILE="${ROOT_DIR}/airport/helm/values.yaml" "${ROOT_DIR}/common/build-and-push.sh"

echo ""
echo "All demo images pushed to Quay.io."
