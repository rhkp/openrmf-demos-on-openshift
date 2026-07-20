# Office Demo — Podman Local Validation

Baseline validation on a Linux VM **before** OpenShift deployment. Confirms patrol dispatch, fleet monitoring, and (optionally) RMF Web floor-plan UI using the same [`common/Dockerfile`](../common/Dockerfile) as production.

> **Scope:** The **office** world is a **single-level** floor plan. For multi-level maps use the [hotel demo](../hotel/README.md) after office passes validation.

## Target environment

| Item | Notes |
|---|---|
| OS | Ubuntu 22.04+ (x86_64) |
| RAM | **≥ 16 GiB** recommended (30 GiB ideal for Gazebo GUI) |
| Container engine | **Podman** (Docker CLI works as `PODMAN=docker` fallback) |
| Display | **xrdp + XFCE** for Windows Remote Desktop verification |
| Repo | Clone `openrmf-demos-on-openshift` |

### Example: AWS EC2 validation host

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<your-validation-vm>
```

Install Podman if missing:

```bash
sudo apt-get update
sudo apt-get install -y podman
```

On **xrdp** sessions, rootless Podman may fail with `libpod-...scope` / cgroup errors. Fix once per user:

```bash
mkdir -p ~/.config/containers
printf '[engine]\ncgroup_manager = "cgroupfs"\n' > ~/.config/containers/containers.conf
```

## Quick start

```bash
git clone https://github.com/rhkp/openrmf-demos-on-openshift.git
cd openrmf-demos-on-openshift
chmod +x office/run-podman-local.sh

# First build (30–60 min)
./office/run-podman-local.sh build

# Headless validation (no GUI)
./office/run-podman-local.sh start

# GUI on xrdp desktop (for Windows RDP)
export DISPLAY=:10.0    # or echo $DISPLAY inside your xrdp session
xhost +local:
./office/run-podman-local.sh start-desktop
```

## Validation checklist

### 1. Simulation starts

```bash
./office/run-podman-local.sh status
podman logs -f rmf-office-simulation
```

**Pass:** Gazebo/ignition loads `office` world; fleet adapter logs appear; no fatal errors.

### 2. Fleet monitor

```bash
podman logs -f rmf-office-fleet-monitor
```

**Pass:** `[fleet-monitor] Subscribing to fleet states...` then periodic X/Y position logs.

### 3. Task dispatch (auto-patrol)

```bash
podman logs -f rmf-office-task-dispatch
```

**Pass:** Patrol `coe` → `lounge`, 3 loops accepted (`'success': True`).

If auto-dispatch times out:

```bash
./office/run-podman-local.sh patrol
```

### 4. Robot movement

In simulation logs or Gazebo (desktop mode):

```bash
podman logs rmf-office-simulation 2>&1 | grep -E "tinyRobot|navigat|patrol"
```

**Pass:** `tinyRobot_*` receives path commands and reaches waypoints.

### 5. Floor plan monitoring (optional — RMF Web)

Office map is **one level**. Enable RMF Web:

```bash
WITH_RMF_WEB=1 ./office/run-podman-local.sh start
```

Open in browser on the VM (or tunneled): `http://localhost:3000`

**Pass:** 2D map shows robots and task state. Stub auth is preconfigured (`admin` / demo JWT).

For Gazebo in browser without xrdp:

```bash
WITH_NOVNC=1 ./office/run-podman-local.sh start-viz
# http://localhost:8080/vnc.html  (connect to VNC)
```

## Architecture (local Podman)

Mirrors the OpenShift pod design using `--network host` and `ROS_LOCALHOST_ONLY=1`:

| Container | Role |
|---|---|
| `rmf-office-simulation` | Gazebo + RMF office world |
| `rmf-office-fleet-monitor` | Logs `/fleet_states` |
| `rmf-office-task-dispatch` | Auto-patrol on startup |
| `rmf-office-api` | (optional) RMF Web API :8000 |
| `rmf-office-dashboard` | (optional) RMF Web UI :3000 |
| `rmf-office-novnc` | (optional) Browser VNC :8080 |

Shared volume: `openrmf-office-ros` → `/opt/rmf/.ros` (logs + dispatch marker).

## Configuration workarounds

| Issue | Workaround |
|---|---|
| **Podman cgroup / `libpod-...scope` Access denied** | In xrdp sessions, use cgroupfs: `mkdir -p ~/.config/containers && printf '[engine]\ncgroup_manager = "cgroupfs"\n' > ~/.config/containers/containers.conf` then retry |
| **Podman: short-name did not resolve** | Use fully qualified base image (`docker.io/osrf/ros:humble-desktop` in `common/Dockerfile`) or add `unqualified-search-registries = ["docker.io"]` in `/etc/containers/registries.conf` |
| **No Podman, only Docker** | `PODMAN=docker ./office/run-podman-local.sh start` |
| **DISPLAY not set (xrdp)** | Inside RDP session: `export DISPLAY=:10.0` (or `echo $DISPLAY`). Run `xhost +local:` |
| **Gazebo black / GL errors** | `export LIBGL_ALWAYS_SOFTWARE=1` (set in launch scripts). Ensure enough RAM |
| **Auto-dispatch `Did not get a response`** | Wait 2 min after sim start; run `./office/run-podman-local.sh patrol` |
| **RMF Web API not connecting** | Start with `WITH_RMF_WEB=1`; fleet adapters need `server_uri:=ws://localhost:8000/_internal` (default in launch scripts) |
| **Port 8080/3000 in use** | `podman rm -f rmf-office-novnc rmf-office-dashboard` or change publish ports in script |
| **Re-run patrol** | `podman volume rm openrmf-office-ros` (clears dispatch marker) or `podman rm -f rmf-office-task-dispatch` and restart |
| **Build OOM** | Use instance with ≥16 GiB RAM; build with `podman build --memory=8g ...` |
| **Multi-level maps** | Office is single-floor; validate hotel/airport separately |

## Stop / reset

```bash
./office/run-podman-local.sh stop
podman volume rm openrmf-office-ros   # full reset
```

## Relation to OpenShift

| Local Podman | OpenShift |
|---|---|
| `run-podman-local.sh` | `deploy-openshift.sh` + Helm |
| `--network host` | Single pod, shared localhost |
| `openrmf-office-ros` volume | `emptyDir` for `/opt/rmf/.ros` |
| `openrmf-office-demo:local` | `quay.io/.../openrmf-openshift-office-demo:certified` |
| xrdp / noVNC | OpenShift Route + noVNC sidecar |

After local validation passes, build and push with:

```bash
VALUES_FILE=office/helm/values.yaml ./common/build-and-push.sh
./office/deploy-openshift.sh
```
