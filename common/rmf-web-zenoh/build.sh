#!/usr/bin/env bash
# Build and push the RMF Web API server image with Zenoh middleware support
# (common/rmf-web-zenoh/Dockerfile). This image had no build script at all
# until now — it was built and pushed manually at some point and nobody
# had a repeatable way to redo it. See ../IMAGES.md for how this fits with
# the other images in this repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PODMAN="${PODMAN:-podman}"
IMAGE="${IMAGE:-quay.io/rhkp/openrmf-rmf-web-zenoh:latest}"
SKIP_PUSH="${SKIP_PUSH:-0}"

echo "==> Building ${IMAGE}"
"${PODMAN}" build \
  --platform linux/amd64 \
  -f "${SCRIPT_DIR}/Dockerfile" \
  -t "${IMAGE}" \
  "${SCRIPT_DIR}"

if [[ "${SKIP_PUSH}" == "1" ]]; then
  echo "==> Skipping push (SKIP_PUSH=1)"
  exit 0
fi

echo "==> Pushing ${IMAGE} to Quay.io"
echo "    (run 'podman login quay.io' first if not already authenticated)"
"${PODMAN}" push "${IMAGE}"

echo "==> Done: ${IMAGE}"
