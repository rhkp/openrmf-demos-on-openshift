#!/usr/bin/env bash
# Rewrite hardcoded localhost URLs in the demo-dashboard image for OpenShift Routes.
set -eo pipefail

: "${RMF_SERVER_URL:?RMF_SERVER_URL is required}"
: "${TRAJECTORY_SERVER_URL:?TRAJECTORY_SERVER_URL is required}"

echo "[dashboard] Injecting public URLs"
echo "  RMF_SERVER_URL=${RMF_SERVER_URL}"
echo "  TRAJECTORY_SERVER_URL=${TRAJECTORY_SERVER_URL}"

mapfile -t files < <(
  find / -type f \( -name '*.js' -o -name '*.html' -o -name '*.json' \) 2>/dev/null \
    | xargs grep -l 'localhost:8000' 2>/dev/null || true
)

for file in "${files[@]}"; do
  sed -i \
    -e "s|http://localhost:8000|${RMF_SERVER_URL}|g" \
    -e "s|https://localhost:8000|${RMF_SERVER_URL}|g" \
    -e "s|ws://localhost:8006|${TRAJECTORY_SERVER_URL}|g" \
    -e "s|wss://localhost:8006|${TRAJECTORY_SERVER_URL}|g" \
    "${file}" || true
done

echo "[dashboard] Starting demo dashboard"
if [[ -x /docker-entrypoint.sh ]]; then
  exec /docker-entrypoint.sh "$@"
fi

if command -v node >/dev/null 2>&1; then
  for candidate in \
    /opt/rmf-web/packages/dashboard/server.js \
    /opt/rmf-web/packages/api-server/dist/index.js \
    /app/server.js; do
    if [[ -f "${candidate}" ]]; then
      exec node "${candidate}"
    fi
  done
fi

exec "$@"
