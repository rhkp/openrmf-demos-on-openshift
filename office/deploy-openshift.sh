#!/usr/bin/env bash
# Build image with Podman, push to Quay.io, deploy office demo via Helm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${SCRIPT_DIR}/helm"
VALUES_FILE="${VALUES_FILE:-${CHART_DIR}/values.yaml}"
RELEASE_NAME="${RELEASE_NAME:-rmf-office-demo}"
SKIP_BUILD="${SKIP_BUILD:-0}"

command -v helm >/dev/null 2>&1 || {
  echo "helm is required but not installed" >&2
  exit 1
}

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "Missing ${VALUES_FILE}" >&2
  echo "Copy ${CHART_DIR}/values.yaml.example to ${CHART_DIR}/values.yaml and customize." >&2
  exit 1
fi

NAMESPACE="$(awk '/^namespace:/{found=1; next} found && /^[[:space:]]+name:/{print $2; exit}' "${VALUES_FILE}")"
NAMESPACE="${NAMESPACE:-rmf-demos}"

if [[ "${SKIP_BUILD}" != "1" ]]; then
  echo "==> Building and pushing image with Podman"
  VALUES_FILE="${VALUES_FILE}" "${ROOT_DIR}/common/build-and-push.sh"
else
  echo "==> Skipping image build/push (SKIP_BUILD=1)"
fi

echo "==> Updating Helm chart dependencies"
helm dependency update "${CHART_DIR}" >/dev/null

echo "==> Deploying Helm release ${RELEASE_NAME} (namespace: ${NAMESPACE})"
helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" \
  -f "${VALUES_FILE}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout 15m

RMF_IMAGE="$("${ROOT_DIR}/common/scripts/read-helm-image.sh" "${VALUES_FILE}")"

echo ""
echo "Office demo ready (image: ${RMF_IMAGE}). Useful commands:"
echo "  helm status ${RELEASE_NAME} -n ${NAMESPACE}"
echo ""
echo "Zenoh Router:"
echo "  oc logs -f deployment/${RELEASE_NAME}-zenoh-router -n ${NAMESPACE}"
echo ""
echo "Simulation Pod:"
echo "  oc logs -f deployment/${RELEASE_NAME} -n ${NAMESPACE} -c simulation"
echo "  oc logs -f deployment/${RELEASE_NAME} -n ${NAMESPACE} -c fleet-monitor"
echo "  oc logs -f deployment/${RELEASE_NAME} -n ${NAMESPACE} -c task-dispatch"
echo "  oc rsh deployment/${RELEASE_NAME} -n ${NAMESPACE} -c simulation"
echo ""
echo "RMF Web Pod:"
echo "  oc logs -f deployment/${RELEASE_NAME}-rmf-web -n ${NAMESPACE} -c rmf-api-server"
echo "  oc logs -f deployment/${RELEASE_NAME}-rmf-web -n ${NAMESPACE} -c rmf-dashboard"

RMF_WEB_ENABLED="$(awk '/^rmfWeb:/{found=1; next} found && /^novnc:/{exit} found && /^[[:space:]]+enabled:/{print $2; exit}' "${VALUES_FILE}")"
NOVNC_ENABLED="$(awk '/^novnc:/{found=1; next} found && /^[[:space:]]+enabled:/{print $2; exit}' "${VALUES_FILE}")"

if [[ "${RMF_WEB_ENABLED}" == "true" ]]; then
  CLUSTER_DOMAIN="$(awk '/^rmfWeb:/{found=1; next} found && /^novnc:/{exit} found && /^[[:space:]]+clusterDomain:/{print $2; exit}' "${VALUES_FILE}")"
  DASH_HOST="$(awk '/^rmfWeb:/{found=1; next} found && /^novnc:/{exit} found && /^[[:space:]]+dashboardHost:/{print $2; exit}' "${VALUES_FILE}")"
  DASH_HOST="${DASH_HOST:-${RELEASE_NAME}-dashboard-${NAMESPACE}}"
  echo ""
  echo "RMF Web dashboard: https://${DASH_HOST}.${CLUSTER_DOMAIN}"
fi

if [[ "${NOVNC_ENABLED}" == "true" ]]; then
  NOVNC_DOMAIN="$(awk '/^novnc:/{found=1; next} found && /^[[:space:]]+clusterDomain:/{print $2; exit}' "${VALUES_FILE}")"
  NOVNC_HOST="$(awk '/^novnc:/{found=1; next} found && /^[[:space:]]+novncHost:/{print $2; exit}' "${VALUES_FILE}")"
  NOVNC_HOST="${NOVNC_HOST:-${RELEASE_NAME}-novnc-${NAMESPACE}}"
  echo "noVNC (Gazebo/RViz): https://${NOVNC_HOST}.${NOVNC_DOMAIN}"
fi
