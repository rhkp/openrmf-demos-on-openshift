#!/usr/bin/env bash
# Build image with Podman, push to Quay.io, deploy hotel demo via Helm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${SCRIPT_DIR}/helm"
VALUES_FILE="${VALUES_FILE:-${CHART_DIR}/values.yaml}"
RELEASE_NAME="${RELEASE_NAME:-rmf-hotel-demo}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SCALE_DOWN_OFFICE="${SCALE_DOWN_OFFICE:-1}"

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

if [[ "${SCALE_DOWN_OFFICE}" == "1" ]] && command -v oc >/dev/null 2>&1; then
  if oc get deployment rmf-office-demo -n "${NAMESPACE}" >/dev/null 2>&1; then
    REPLICAS="$(oc get deployment rmf-office-demo -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    if [[ "${REPLICAS}" != "0" ]]; then
      echo "==> Scaling down rmf-office-demo (one active demo per namespace)"
      oc scale deployment/rmf-office-demo -n "${NAMESPACE}" --replicas=0
    fi
  fi
fi

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
  --timeout 20m

RMF_IMAGE="$("${ROOT_DIR}/common/scripts/read-helm-image.sh" "${VALUES_FILE}")"

echo ""
echo "Hotel demo ready (image: ${RMF_IMAGE}). Useful commands:"
echo "  helm status ${RELEASE_NAME} -n ${NAMESPACE}"
echo "  oc logs -f deployment/${RELEASE_NAME} -n ${NAMESPACE} -c simulation"
echo "  oc logs -f deployment/${RELEASE_NAME} -n ${NAMESPACE} -c fleet-monitor"
echo "  oc logs -f deployment/${RELEASE_NAME} -n ${NAMESPACE} -c task-dispatch"
echo "  oc rsh deployment/${RELEASE_NAME} -n ${NAMESPACE} -c simulation"

RMF_WEB_ENABLED="$(awk '/^rmfWeb:/{found=1; next} found && /^novnc:/{exit} found && /^  enabled:/{print $2; exit}' "${VALUES_FILE}")"
RMF_WEB_ROUTES_ENABLED="$(awk '/^rmfWeb:/{found=1; next} found && /^novnc:/{exit} found && /^  routes:/{r=1; next} r && /^    enabled:/{print $2; exit}' "${VALUES_FILE}")"
NOVNC_ENABLED="$(awk '/^novnc:/{found=1; next} found && /^[a-zA-Z]/ && !/^  /{exit} found && /^  enabled:/{print $2; exit}' "${VALUES_FILE}")"
NOVNC_ROUTES_ENABLED="$(awk '/^novnc:/{found=1; next} found && /^[a-zA-Z]/ && !/^  /{exit} found && /^  routes:/{r=1; next} r && /^    enabled:/{print $2; exit}' "${VALUES_FILE}")"

if [[ "${RMF_WEB_ENABLED}" == "true" && "${RMF_WEB_ROUTES_ENABLED}" == "true" ]]; then
  CLUSTER_DOMAIN="$(awk '/^rmfWeb:/{found=1; next} found && /^novnc:/{exit} found && /^[[:space:]]+clusterDomain:/{print $2; exit}' "${VALUES_FILE}")"
  DASH_HOST="$(awk '/^rmfWeb:/{found=1; next} found && /^novnc:/{exit} found && /^[[:space:]]+dashboardHost:/{print $2; exit}' "${VALUES_FILE}")"
  DASH_HOST="${DASH_HOST:-${RELEASE_NAME}-dashboard-${NAMESPACE}}"
  echo ""
  echo "RMF Web dashboard: https://${DASH_HOST}.${CLUSTER_DOMAIN}"
fi

if [[ "${NOVNC_ENABLED}" == "true" && "${NOVNC_ROUTES_ENABLED}" == "true" ]]; then
  NOVNC_DOMAIN="$(awk '/^novnc:/{found=1; next} found && /^[[:space:]]+clusterDomain:/{print $2; exit}' "${VALUES_FILE}")"
  NOVNC_HOST="$(awk '/^novnc:/{found=1; next} found && /^[[:space:]]+novncHost:/{print $2; exit}' "${VALUES_FILE}")"
  NOVNC_HOST="${NOVNC_HOST:-${RELEASE_NAME}-novnc-${NAMESPACE}}"
  echo "noVNC (Gazebo/RViz): https://${NOVNC_HOST}.${NOVNC_DOMAIN}"
fi

echo ""
echo "Submit patrol manually:"
echo "  oc exec deployment/${RELEASE_NAME} -n ${NAMESPACE} -c simulation -- bash -c \\"
echo "    'source /opt/rmf/scripts/ros-env.sh && ros2 run rmf_demos_tasks dispatch_patrol -p restaurant L3_master_suite -n 1 --use_sim_time'"
