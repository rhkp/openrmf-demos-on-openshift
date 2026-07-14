#!/bin/sh
set -e

cp -r /opt/dashboard/. /dashboard/

API_URL="${RMF_SERVER_URL}"
TRAJ_URL="${TRAJECTORY_SERVER_URL}"

if [ -f /dashboard/app-config.json ]; then
  sed -i \
    -e "s|\"rmfServerUrl\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"rmfServerUrl\": \"${API_URL}\"|g" \
    -e "s|\"trajectoryServerUrl\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"trajectoryServerUrl\": \"${TRAJ_URL}\"|g" \
    /dashboard/app-config.json
fi

find /dashboard -type f \( -name '*.js' -o -name '*.html' -o -name '*.json' \) | while read -r f; do
  if grep -q 'localhost:8000\|localhost:8006' "$f" 2>/dev/null; then
    sed -i \
      -e "s|http://localhost:8000|${API_URL}|g" \
      -e "s|https://localhost:8000|${API_URL}|g" \
      -e "s|ws://localhost:8006|${TRAJ_URL}|g" \
      -e "s|wss://localhost:8006|${TRAJ_URL}|g" \
      -e "s|http://localhost:8006|${TRAJ_URL}|g" \
      "$f"
  fi
done

echo "[dashboard-init] Patched dashboard assets (API=${API_URL}, trajectory=${TRAJ_URL})"
