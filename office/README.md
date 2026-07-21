# Office Demo

Indoor office world from [rmf_demos](https://github.com/open-rmf/rmf_demos) (`office.launch.xml`) — tinyRobot fleet, Gazebo simulation, and a sample patrol task (`coe` → `lounge`, 3 loops).

**Stack:** Podman build → Quay.io → Helm on OpenShift  
**Visualization:** RMF Web dashboard (2D) + noVNC (Gazebo/RViz in browser)

> **Podman local validation (pre-OpenShift):** See [PODMAN-VALIDATION.md](PODMAN-VALIDATION.md) and `./run-podman-local.sh`.

---

## Prerequisites

- OpenShift 4.x cluster and `oc` logged in
- `helm` and **Podman** on your build machine
- Quay.io account with push access (`podman login quay.io`)

---

## 1. Configure (once)

```bash
cp office/helm/values.yaml.example office/helm/values.yaml
```

Edit `office/helm/values.yaml`:

| Key | Set to |
|---|---|
| `namespace.name` | Your OpenShift project (e.g. `rmf-demos`) |
| `image.fullRef` | `quay.io/<org>/openrmf-openshift-office-demo:certified` |
| `novnc.image` | `quay.io/<org>/openrmf-openshift-office-demo:novnc` |
| `rmfWeb.routes.clusterDomain` | Your cluster apps domain |
| `novnc.routes.clusterDomain` | Same apps domain |

`values.yaml` is gitignored — never commit registry credentials or local cluster settings.

---

## 2. Launch the demo

From the **repo root**:

```bash
chmod +x office/deploy-openshift.sh common/build-and-push.sh
./office/deploy-openshift.sh
```

This will:

1. Build and push the simulation image (`:certified`) and noVNC sidecar (`:novnc`) for **linux/amd64**
2. Update Helm dependencies (`common/helm/openrmf-lib`)
3. Deploy release `rmf-office-demo` into your namespace

First build can take **30+ minutes**. Re-deploy without rebuilding:

```bash
SKIP_BUILD=1 ./office/deploy-openshift.sh
```

### Check the pod

```bash
NAMESPACE=rmf-demos   # match values.yaml

oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=openrmf-office-demo
```

**Pass:** `6/6 Running` when `rmfWeb.enabled` and `novnc.enabled` are both true.

| Container | Role |
|---|---|
| `simulation` | Gazebo + RMF office world |
| `fleet-monitor` | Logs robot X/Y every 10s |
| `task-dispatch` | Auto-patrol on startup (once per pod) |
| `rmf-api-server` | RMF Web API |
| `rmf-dashboard` | RMF Web UI (nginx) |
| `novnc` | Browser stream of Gazebo/RViz |

---

## 3. View the demo

Get Route URLs:

```bash
oc get routes -n "${NAMESPACE}" | grep rmf-office
```

Or read them from deploy output / `values.yaml` hosts + `clusterDomain`.

| View | URL pattern |
|---|---|
| **noVNC** (Gazebo + RViz) | `https://<novncHost>.<clusterDomain>` |
| **RMF Web dashboard** | `https://<dashboardHost>.<clusterDomain>` |

**noVNC:** open the route, click **Connect** (or `vnc.html`). Give Gazebo ~1–2 minutes after pod start.

**RMF Web:** 2D map, fleet state, tasks. Stub auth is preconfigured for the demo.

### 3b. View the demo (port-forward — no routes)

If routes are disabled (`rmfWeb.routes.enabled: false`, `novnc.routes.enabled: false`), use `oc port-forward` for secure local-only access — nothing is exposed publicly.

```bash
./office/port-forward.sh <namespace> [release-name]

# Example:
./office/port-forward.sh arhkp1-openrmf rmf-office-demo
```

| View | Local URL |
|---|---|
| **RMF Web dashboard** | `http://localhost:3000` |
| **noVNC** (Gazebo/RViz) | `http://localhost:6080` |

Custom ports via environment variables:

```bash
DASH_PORT=8080 NOVNC_PORT=9090 ./office/port-forward.sh arhkp1-openrmf
```

The dashboard nginx proxies API and trajectory WebSocket requests to internal services — only two port-forwards are needed.

---

## 4. Submit a patrol task

The pod tries to auto-dispatch on startup. If timing is off you may see `Did not get a response` in `task-dispatch` logs — **submit manually** (OpenShift equivalent of the Docker `docker exec` flow):

```bash
NAMESPACE=rmf-demos   # match values.yaml

oc exec deployment/rmf-office-demo -n "${NAMESPACE}" -c simulation -- bash -c '
source /opt/rmf/scripts/ros-env.sh
ros2 run rmf_demos_tasks dispatch_patrol -p coe lounge -n 3 --use_sim_time
'
```

**Success** looks like:

```json
{
  "success": true,
  "state": {
    "booking": { "id": "patrol.dispatch-0" },
    "category": "patrol",
    "detail": { "places": ["coe", "lounge"], "rounds": 3 },
    "dispatch": { "status": "queued" }
  }
}
```

Robots should start moving in **noVNC** within a few seconds.

### Watch movement

```bash
# Robot positions (every 10s)
oc logs -f deployment/rmf-office-demo -n "${NAMESPACE}" -c fleet-monitor

# Navigation events
oc logs -f deployment/rmf-office-demo -n "${NAMESPACE}" -c simulation | grep tinyRobot
```

### Interactive shell (optional)

```bash
oc rsh deployment/rmf-office-demo -n "${NAMESPACE}" -c simulation
source /opt/rmf/scripts/ros-env.sh
ros2 run rmf_demos_tasks dispatch_patrol -p coe lounge -n 3 --use_sim_time
```

### Re-run patrol

Auto-dispatch runs **once per pod** (marker file in `task-dispatch`). To dispatch again:

- Run the `oc exec` command above (any time), **or**
- Restart the pod to trigger auto-dispatch again:

```bash
oc delete pod -l app.kubernetes.io/name=openrmf-office-demo -n "${NAMESPACE}"
```

---

## 5. Verify end-to-end

```bash
NAMESPACE=rmf-demos

# 1. Pod healthy
oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=openrmf-office-demo

# 2. Simulation up
oc logs deployment/rmf-office-demo -n "${NAMESPACE}" -c simulation --tail=20

# 3. Fleet publishing
oc exec deployment/rmf-office-demo -n "${NAMESPACE}" -c simulation -- bash -c \
  'source /opt/rmf/scripts/ros-env.sh && ros2 topic echo /fleet_states --once'

# 4. Patrol queued (after manual or auto dispatch)
oc logs deployment/rmf-office-demo -n "${NAMESPACE}" -c simulation --tail=5 | grep navigat
```

---

## Configuration reference

| Setting | Value |
|---|---|
| Launch file | `office.launch.xml` |
| Sample patrol | `coe` → `lounge`, 3 rounds |
| Dispatch script (auto) | `office/scripts/dispatch-task.sh` |
| Readiness wait | `dispatch.readyWaitSeconds` (default 30) |
| Helm release | `rmf-office-demo` |
| Shared viz library | `common/helm/openrmf-lib/` |

### Helm-only deploy

```bash
helm dependency update office/helm
helm upgrade --install rmf-office-demo office/helm \
  -f office/helm/values.yaml \
  -n "${NAMESPACE}" --create-namespace --wait
```

### Tear down

```bash
helm uninstall rmf-office-demo -n "${NAMESPACE}"
```

---

## Notes

- Builds use `--platform linux/amd64` (required when building on Apple Silicon).
- noVNC needs `xvfb` / `x11vnc` in the simulation image — use a full build, not `SKIP_BUILD=1`, after Dockerfile changes.
- Run **one demo per namespace** (ROS discovery is pod-local).
- `office/helm/values.yaml` is local config; commit changes via `values.yaml.example` only.
