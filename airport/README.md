# Airport Demo

Large airport terminal world from [rmf_demos](https://github.com/open-rmf/rmf_demos#airport-terminal-world) (`airport_terminal.launch.xml`) — multiple robot fleets, lanes, doors, lifts, and infrastructure interactions on a large map.

**Stack:** Podman build → Quay.io → Helm on OpenShift  
**Visualization:** RMF Web dashboard (2D) + noVNC (Gazebo/RViz in browser)  
**Image:** Dedicated `openrmf-openshift-airport-demo` on Quay.io (same Dockerfile, separate repository).

---

## Prerequisites

- OpenShift 4.x cluster and `oc` logged in
- `helm` and **Podman** on your build machine
- Quay.io account with push access (`podman login quay.io`)

> **One demo per namespace.** The deploy script scales down `rmf-office-demo` and `rmf-hotel-demo` automatically. Set `SCALE_DOWN_OTHER=0` to skip.

---

## 1. Configure (once)

```bash
cp airport/helm/values.yaml.example airport/helm/values.yaml
```

Edit `airport/helm/values.yaml`:

| Key | Set to |
|---|---|
| `namespace.name` | Your OpenShift project |
| `image.fullRef` | `quay.io/<org>/openrmf-openshift-airport-demo:certified` |
| `novnc.image` | `quay.io/<org>/openrmf-openshift-airport-demo:novnc` |
| `rmfWeb.routes.clusterDomain` | Your cluster apps domain |
| `novnc.routes.clusterDomain` | Same apps domain |

`values.yaml` is gitignored.

---

## 2. Launch the demo

From the **repo root**:

```bash
chmod +x airport/deploy-openshift.sh
./airport/deploy-openshift.sh
```

This rebuilds the image (adds `airport/scripts/`), pushes to Quay, scales down other demos, and deploys `rmf-airport-demo`.

Airport startup is slower (large map + multiple fleets). Helm wait timeout is **25 minutes**.

Re-deploy without rebuilding:

```bash
SKIP_BUILD=1 ./airport/deploy-openshift.sh
```

### Check the pod

```bash
NAMESPACE=rmf-demos   # match values.yaml

oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=openrmf-airport-demo
```

**Pass:** `6/6 Running` when `rmfWeb.enabled` and `novnc.enabled` are both true.

| Container | Role |
|---|---|
| `simulation` | Gazebo + RMF airport terminal world |
| `fleet-monitor` | Logs robot X/Y every 10s |
| `task-dispatch` | Auto-patrol on startup (once per pod) |
| `rmf-api-server` | RMF Web API |
| `rmf-dashboard` | RMF Web UI |
| `novnc` | Browser stream of Gazebo/RViz |

---

## 3. View the demo

Routes are **disabled by default** (`routes.enabled: false`). Use cluster-internal access or enable routes in `values.yaml`.

When routes are enabled:

```bash
oc get routes -n "${NAMESPACE}" | grep rmf-airport
```

| View | URL pattern |
|---|---|
| **noVNC** | `https://<novncHost>.<clusterDomain>` |
| **RMF Web** | `https://<dashboardHost>.<clusterDomain>` |

---

## 4. Submit tasks

Airport supports **Loop (patrol)**, **Delivery**, and **Clean** tasks per the [upstream demo](https://github.com/open-rmf/rmf_demos/#airport-terminal-world).

### Patrol (loop): s07 → n12

Auto-dispatched on startup (3 loops). If timing is off, submit manually:

```bash
NAMESPACE=rmf-demos

oc exec deployment/rmf-airport-demo -n "${NAMESPACE}" -c simulation -- bash -c '
source /opt/rmf/scripts/ros-env.sh
ros2 run rmf_demos_tasks dispatch_patrol -p s07 n12 -n 3 --use_sim_time
'
```

### Delivery task

```bash
oc exec deployment/rmf-airport-demo -n "${NAMESPACE}" -c simulation -- bash -c '
source /opt/rmf/scripts/ros-env.sh
ros2 run rmf_demos_tasks dispatch_delivery -p mopcart_pickup -ph mopcart_dispenser -d spill -dh mopcart_collector --use_sim_time
'
```

### Clean task: zone_3

```bash
oc exec deployment/rmf-airport-demo -n "${NAMESPACE}" -c simulation -- bash -c '
source /opt/rmf/scripts/ros-env.sh
ros2 run rmf_demos_tasks dispatch_clean -cs zone_3 --use_sim_time
'
```

### Watch movement

```bash
oc logs -f deployment/rmf-airport-demo -n "${NAMESPACE}" -c fleet-monitor
oc logs -f deployment/rmf-airport-demo -n "${NAMESPACE}" -c simulation | grep -E "tinyRobot|cleaner|delivery"
```

### Re-run auto-dispatch

```bash
oc delete pod -l app.kubernetes.io/name=openrmf-airport-demo -n "${NAMESPACE}"
```

---

## Configuration reference

| Setting | Value |
|---|---|
| Launch file | `airport_terminal.launch.xml` |
| Auto patrol | `s07` → `n12`, 3 loops |
| Startup wait | `dispatch.startupWaitSeconds: 45` |
| Adapter wait | `dispatch.readyWaitSeconds: 120` |
| Shared memory | `shm.sizeLimit: 6Gi` |
| Helm release | `rmf-airport-demo` |

### Tear down

```bash
helm uninstall rmf-airport-demo -n "${NAMESPACE}"
```

---

## Notes

- Uses a **dedicated Quay image** (`openrmf-openshift-airport-demo`) — built from the same Dockerfile as office/hotel.
- Airport needs **more CPU/RAM** than office or hotel (large terminal map).
- After adding `airport/scripts/` to the Dockerfile, run a full build once (`./airport/deploy-openshift.sh` without `SKIP_BUILD`).
