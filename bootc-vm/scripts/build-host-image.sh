#!/usr/bin/env bash
# Build the bootc host image and push it to Quay, so bootc-image-builder
# (run separately, see build-ami.sh) can pull it by reference.
#
# Run on the AWS build VM (x86_64) — see README.md "Architecture" for why
# this can't be built on the user's arm64 Mac.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTC_VM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PODMAN="${PODMAN:-podman}"
HOST_IMAGE="${HOST_IMAGE:-quay.io/rhkp/openrmf-office-bootc-host:latest}"
SKIP_PUSH="${SKIP_PUSH:-0}"

echo "Building ${HOST_IMAGE} from ${BOOTC_VM_DIR}/Containerfile..."
"${PODMAN}" build --platform linux/amd64 -f "${BOOTC_VM_DIR}/Containerfile" -t "${HOST_IMAGE}" "${BOOTC_VM_DIR}"

if [[ "${SKIP_PUSH}" == "1" ]]; then
  echo "SKIP_PUSH=1 set; not pushing. Image available locally as ${HOST_IMAGE}."
  exit 0
fi

echo "Pushing ${HOST_IMAGE}..."
"${PODMAN}" push "${HOST_IMAGE}"
echo "Done: ${HOST_IMAGE}"
