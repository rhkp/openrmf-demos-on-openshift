# Hotel Demo

Multi-level hotel world from [rmf_demos](https://github.com/open-rmf/rmf_demos#hotel-world) (`hotel.launch.xml`) — lobby, two guest levels, lifts, doors, and **3 robot fleets (4 robots)**.

**Stack:** Podman build → Quay.io → Helm on OpenShift  
**Visualization:** RMF Web dashboard (2D) + noVNC (Gazebo/RViz in browser)  
**Image:** Dedicated `openrmf-openshift-hotel-demo` on Quay.io (same Dockerfile, separate repository).

---

## Prerequisites

- OpenShift 4.x cluster and `oc` logged in
- `helm` and **Podman** on your build machine
- Quay.io account with push access (`podman login quay.io`)

> **One demo per namespace.** The deploy script scales down `rmf-office-demo` and `rmf-airport-demo` automatically. Set `SCALE_DOWN_OTHER=0` to skip.

---

## 1. Configure (once)

```bash
cp hotel/helm/values.yaml.example hotel/helm/values.yaml
```

Edit `hotel/helm/values.yaml`:

| Key | Set to |
|---|---|
| `namespace.name` | Your OpenShift project |
| `image.fullRef` | `quay.io/<org>/openrmf-openshift-hotel-demo:certified` |
| `novnc.image` | `quay.io/<org>/openrmf-openshift-hotel-demo:novnc` |
| `rmfWeb.routes.clusterDomain` | Your cluster apps domain (if using routes) |
| `novnc.routes.clusterDomain` | Same apps domain (if using routes) |

`values.yaml` is gitignored.

---

## 2. Launch the demo

From the **repo root**:

```bash
chmod +x hotel/deploy-openshift.sh
./hotel/deploy-openshift.sh
```

This rebuilds the image (adds `hotel/scripts/`), pushes to Quay, scales down other demos, and deploys `rmf-hotel-demo`.

Hotel startup is slower (multi-fleet + lifts). Helm wait timeout is **20 minutes**.

Re-deploy without rebuilding:

```bash
SKIP_BUILD=1 ./hotel/deploy-openshift.sh
```

### Check the pods

```bash
NAMESPACE=rmf-demos   # match values.yaml

oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=openrmf-hotel-demo
```

**Pass:** Three pods running — simulation `4/4`, rmf-web `2/2`, zenoh-router `1/1`.

| Pod | Container | Role |
|---|---|---|
| simulation | `simulation` | Gazebo + RMF hotel world (multi-level) |
| simulation | `fleet-monitor` | Logs robot X/Y every 10s |
| simulation | `task-dispatch` | Auto-patrol on startup (once per pod) |
| simulation | `novnc` | Browser stream of Gazebo/RViz |
| rmf-web | `rmf-api-server` | RMF Web API (Zenoh middleware) |
| rmf-web | `rmf-dashboard` | RMF Web UI (nginx) |
| zenoh-router | `zenoh-router` | Central Zenoh message broker |

---

## 3. View the demo

Routes are **disabled by default** (`routes.enabled: false`). Use port-forward for local access or enable routes in `values.yaml`.

When routes are enabled:

```bash
oc get routes -n "${NAMESPACE}" | grep rmf-hotel
```

| View | URL pattern |
|---|---|
| **noVNC** | `https://<novncHost>.<clusterDomain>` |
| **RMF Web** | `https://<dashboardHost>.<clusterDomain>` |

### 3b. View the demo (port-forward — no routes)

If routes are disabled (`rmfWeb.routes.enabled: false`, `novnc.routes.enabled: false`), use `oc port-forward` for secure local-only access — nothing is exposed publicly.

```bash
./hotel/port-forward.sh <namespace> [release-name]

# Example:
./hotel/port-forward.sh arhkp1-openrmf rmf-hotel-demo
```

| View | Local URL |
|---|---|
| **RMF Web dashboard** | `http://localhost:3000` |
| **noVNC** (Gazebo/RViz) | `http://localhost:6080` |

Custom ports via environment variables:

```bash
DASH_PORT=8080 NOVNC_PORT=9090 ./hotel/port-forward.sh arhkp1-openrmf
```

The dashboard nginx proxies API and trajectory WebSocket requests to internal services — only two port-forwards are needed.

---

## 4. Submit tasks

Hotel supports **Loop (patrol)** and **Clean** tasks per the [upstream demo](https://github.com/open-rmf/rmf_demos/#hotel-world).

### Patrol (loop): restaurant → L3_master_suite

Auto-dispatched on startup (1 loop). If timing is off, submit manually:

```bash
NAMESPACE=rmf-demos

oc exec deployment/rmf-hotel-demo -n "${NAMESPACE}" -c simulation -- bash -c '
source /opt/rmf/scripts/ros-env.sh
ros2 run rmf_demos_tasks dispatch_patrol -p restaurant L3_master_suite -n 1 --use_sim_time
'
```

### Clean task: clean_lobby

```bash
oc exec deployment/rmf-hotel-demo -n "${NAMESPACE}" -c simulation -- bash -c '
source /opt/rmf/scripts/ros-env.sh
ros2 run rmf_demos_tasks dispatch_clean -cs clean_lobby --use_sim_time
'
```

### Watch movement

```bash
oc logs -f deployment/rmf-hotel-demo -n "${NAMESPACE}" -c fleet-monitor
oc logs -f deployment/rmf-hotel-demo -n "${NAMESPACE}" -c simulation | grep -E "tinyRobot|cleaner|delivery"
```

### Re-run auto-dispatch

```bash
oc delete pod -l app.kubernetes.io/name=openrmf-hotel-demo -n "${NAMESPACE}"
```

---

## Configuration reference

| Setting | Value |
|---|---|
| Launch file | `hotel.launch.xml` |
| Auto patrol | `restaurant` → `L3_master_suite`, 1 loop |
| Startup wait | `dispatch.startupWaitSeconds: 30` |
| Adapter wait | `dispatch.readyWaitSeconds: 90` |
| Shared memory | `shm.sizeLimit: 64Mi` |
| Helm release | `rmf-hotel-demo` |

### Tear down

```bash
helm uninstall rmf-hotel-demo -n "${NAMESPACE}"
```

---

## Notes

- Uses a **dedicated Quay image** (`openrmf-openshift-hotel-demo`) — built from the same Dockerfile as office/airport.
- Hotel needs **more CPU/RAM** than office (4 robots, lifts, multi-level map).
- After adding `hotel/scripts/` to the Dockerfile, run a full build once (`./hotel/deploy-openshift.sh` without `SKIP_BUILD`).
