#!/usr/bin/env bash
# Port-forward office demo services for local access (no routes needed).
set -euo pipefail

NAMESPACE="${1:-arhkp1-openrmf}"
RELEASE="${2:-rmf-office-demo}"
DASH_PORT="${DASH_PORT:-3000}"
NOVNC_PORT="${NOVNC_PORT:-6080}"

echo "==> Port-forwarding office demo (namespace: ${NAMESPACE})"
echo ""
echo "  Dashboard: http://localhost:${DASH_PORT}"
echo "  noVNC:     http://localhost:${NOVNC_PORT}"
echo ""
echo "Press Ctrl+C to stop."

trap 'kill $(jobs -p) 2>/dev/null' EXIT INT TERM

oc port-forward "svc/${RELEASE}-dashboard" "${DASH_PORT}:80" -n "${NAMESPACE}" &
oc port-forward "svc/${RELEASE}-novnc" "${NOVNC_PORT}:80" -n "${NAMESPACE}" &
wait
