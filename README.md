# OpenRMF Demos on OpenShift

Run [Open-RMF demos](https://github.com/open-rmf/rmf_demos) (ROS 2 Humble + Gazebo) on OpenShift. Each world has its own folder, **Helm chart**, and deploy script.

**Build:** Podman · **Registry:** Quay.io · **Deploy:** Helm

## Repository layout

```
common/
  Dockerfile
  build-and-push.sh
  scripts/
  helm/openrmf-lib/        # Shared RMF Web + noVNC Helm library
  openshift/                # Optional SCC bindings

office/                     # Office world (ready)
  helm/
    Chart.yaml
    values.yaml.example     # Copy → values.yaml (gitignored)
    templates/
  deploy-openshift.sh

airport/                    # Airport terminal world (ready)
  helm/
  deploy-openshift.sh
hotel/                      # Hotel world (ready)
  helm/
  deploy-openshift.sh
```

## Quick start — office demo

### Local validation with Podman (optional)

Validate on a Linux VM **before** OpenShift. See [office/PODMAN-VALIDATION.md](office/PODMAN-VALIDATION.md).

```bash
chmod +x office/run-podman-local.sh
./office/run-podman-local.sh build
./office/run-podman-local.sh start-desktop   # xrdp/GUI, or: start (headless)
```

### 1. Configure Helm values

```bash
cp office/helm/values.yaml.example office/helm/values.yaml
# Edit office/helm/values.yaml — set image.fullRef, pullSecret.name, etc.
```

### 2. Authenticate to Quay

```bash
podman login quay.io
```

### 3. Build, push, and deploy

```bash
chmod +x office/deploy-openshift.sh common/build-and-push.sh
./office/deploy-openshift.sh
```

Re-deploy without rebuild:

```bash
SKIP_BUILD=1 ./office/deploy-openshift.sh
```

Helm only (image already in Quay):

```bash
helm upgrade --install rmf-office-demo office/helm \
  -f office/helm/values.yaml \
  -n rmf-demos --create-namespace --wait
```

## Quick start — hotel demo

See [hotel/README.md](hotel/README.md) for full docs.

```bash
cp hotel/helm/values.yaml.example hotel/helm/values.yaml
# Edit image refs and namespace (hotel image: openrmf-openshift-hotel-demo)
./hotel/deploy-openshift.sh
```

## Quick start — airport demo

See [airport/README.md](airport/README.md) for full docs.

```bash
cp airport/helm/values.yaml.example airport/helm/values.yaml
# Edit image refs and namespace (airport image: openrmf-openshift-airport-demo)
./airport/deploy-openshift.sh
```

## Prerequisites

- OpenShift 4.x cluster
- `oc` and **helm** CLIs
- **Podman** on your build machine
- Quay.io account with push access

## Sensitive / local files (gitignored)

| File | Purpose |
|---|---|
| `office/helm/values.yaml` | Image ref, pull secrets, resources |
| `hotel/helm/values.yaml` | Same pattern |
| `airport/helm/values.yaml` | Same pattern |
| `common/image.env` | Optional fallback for builds without Helm values |
| `.env`, `.env.local` | General secrets |

Committed templates: `values.yaml.example` in each demo's `helm/` folder.

## How it works

| Concern | Approach |
|---|---|
| Image build | Podman (`common/build-and-push.sh` or `common/build-all-demos.sh`) |
| Image registry | Quay.io (`image.fullRef` in `values.yaml`) |
| OpenShift deploy | Helm chart per demo |
| Pull secrets | `pullSecret.name` in `values.yaml` → ServiceAccount |
| Local validation | `office/run-podman-local.sh` (see [office/PODMAN-VALIDATION.md](office/PODMAN-VALIDATION.md)) |

## Adding a new demo

1. Create `<demo>/scripts/dispatch-task.sh`
2. Add `COPY` to `common/Dockerfile`
3. Copy `office/helm/` → `<demo>/helm/`, update `values.yaml.example`
4. Copy `office/deploy-openshift.sh` → `<demo>/deploy-openshift.sh`
5. Rebuild: `VALUES_FILE=<demo>/helm/values.yaml ./common/build-and-push.sh`

## Roadmap

| Phase | Goal | Status |
|---|---|---|
| **1** | Headless sim + logs + fleet monitor + patrol | Done |
| **2** | RMF Web dashboard (2D map, robots, tasks) | **Available** — `rmfWeb.enabled` |
| **3** | noVNC (Gazebo/RViz in browser) | **Available** — `novnc.enabled` |

Both visualizations live in `common/helm/openrmf-lib/` and are wired in the office chart. Enable either or both in `values.yaml`.

See [office/README.md](office/README.md#3-view-the-demo) for browser URLs and verification.
