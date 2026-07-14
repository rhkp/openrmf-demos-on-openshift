#!/usr/bin/env bash
# Build the shared RMF image with Podman and push to Quay.io.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/common/image.env}"
VALUES_FILE="${VALUES_FILE:-}"

PODMAN="${PODMAN:-podman}"
SKIP_PUSH="${SKIP_PUSH:-0}"

resolve_image() {
  if [[ -n "${RMF_IMAGE:-}" ]]; then
    echo "${RMF_IMAGE}"
    return
  fi

  if [[ -n "${VALUES_FILE}" && -f "${VALUES_FILE}" ]]; then
    "${ROOT_DIR}/common/scripts/read-helm-image.sh" "${VALUES_FILE}"
    return
  fi

  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    if [[ -n "${RMF_IMAGE:-}" ]]; then
      echo "${RMF_IMAGE}"
      return
    fi
  fi

  echo "Set image via one of:" >&2
  echo "  - VALUES_FILE=office/helm/values.yaml" >&2
  echo "  - common/image.env (RMF_IMAGE=...)" >&2
  echo "  - export RMF_IMAGE=quay.io/org/image:tag" >&2
  exit 1
}

RMF_IMAGE="$(resolve_image)"

echo "==> Building ${RMF_IMAGE}"
"${PODMAN}" build \
  --platform linux/amd64 \
  -f "${ROOT_DIR}/common/Dockerfile" \
  -t "${RMF_IMAGE}" \
  "${ROOT_DIR}"

if [[ "${SKIP_PUSH}" == "1" ]]; then
  echo "==> Skipping push (SKIP_PUSH=1)"
  exit 0
fi

echo "==> Pushing ${RMF_IMAGE} to Quay.io"
echo "    (run 'podman login quay.io' first if not already authenticated)"
"${PODMAN}" push "${RMF_IMAGE}"

echo "==> Done: ${RMF_IMAGE}"

if [[ -n "${VALUES_FILE}" && -f "${VALUES_FILE}" ]]; then
  NOVNC_ENABLED="$(awk '/^novnc:/{found=1; next} found && /^[a-zA-Z]/ && !/^  /{exit} found && /^  enabled:/{print $2; exit}' "${VALUES_FILE}")"
  NOVNC_IMAGE="$(awk '/^novnc:/{found=1; next} found && /^[a-zA-Z]/ && !/^  /{exit} found && /^  image:/{print $2; exit}' "${VALUES_FILE}")"
  if [[ "${NOVNC_ENABLED}" == "true" && -n "${NOVNC_IMAGE}" ]]; then
    echo "==> Building ${NOVNC_IMAGE}"
    "${PODMAN}" build \
      --platform linux/amd64 \
      -f "${ROOT_DIR}/common/novnc/Dockerfile" \
      -t "${NOVNC_IMAGE}" \
      "${ROOT_DIR}/common/novnc"
    if [[ "${SKIP_PUSH}" != "1" ]]; then
      echo "==> Pushing ${NOVNC_IMAGE} to Quay.io"
      "${PODMAN}" push "${NOVNC_IMAGE}"
    fi
    echo "==> Done: ${NOVNC_IMAGE}"
  fi
fi
