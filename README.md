# OpenRMF Demos on OpenShift

Run [Open-RMF demos](https://github.com/open-rmf/rmf_demos) (ROS 2 Jazzy + Gazebo) on OpenShift. Each world has its own folder, **Helm chart**, and deploy script.

**Images:** built and pushed from the separate
[hummingbird-bootc-robotics-images](../hummingbird-bootc-robotics-images) repo
(bootc-os + RoboStack, `hbr-*` image family). **This repo only deploys** —
it does not build any images.

**Deploy:** Helm · **Registry:** Quay.io

## Repository layout

```
common/
  scripts/read-helm-image.sh # Deploy-time helper (reads image ref out of a values.yaml)
  helm/openrmf-lib/          # Shared RMF Web + noVNC Helm library
  openshift/                 # Namespace/ServiceAccount/SCC (optional)

office/                      # Office world (ready, hbr-* images)
  helm/
    Chart.yaml
    values.yaml.example      # Copy → values.yaml (gitignored)
    templates/
  scripts/                   # Per-demo dispatch scripts
  deploy-openshift.sh
  port-forward.sh

airport/                     # Airport terminal world (frozen — see below)
  helm/
  deploy-openshift.sh
hotel/                       # Hotel world (frozen — see below)
  helm/
  deploy-openshift.sh
```

## Quick start — office demo

### 1. Configure Helm values

```bash
cp office/helm/values.yaml.example office/helm/values.yaml
# Edit office/helm/values.yaml — set image.fullRef, pullSecret.name, etc.
# Images come from quay.io/<org>/hbr-* — see values.yaml.example comments.
```

### 2. Deploy

```bash
chmod +x office/deploy-openshift.sh
./office/deploy-openshift.sh
```

This runs `helm upgrade --install rmf-office-demo-hbr office/helm ...` — no
image build step, since images are pre-built in the
hummingbird-bootc-robotics-images repo.

## Quick start — hotel / airport demos (frozen)

Hotel and airport still deploy fine (their images already exist in Quay),
but their images are **frozen** — the old `common/Dockerfile`-based build
pipeline was removed once office migrated to `hbr-*` images, so these two
can no longer be rebuilt. See the `image.fullRef` comments in
[hotel/helm/values.yaml.example](hotel/helm/values.yaml.example) and
[airport/helm/values.yaml.example](airport/helm/values.yaml.example).

```bash
cp hotel/helm/values.yaml.example hotel/helm/values.yaml
./hotel/deploy-openshift.sh
```

```bash
cp airport/helm/values.yaml.example airport/helm/values.yaml
./airport/deploy-openshift.sh
```

Migrating either to `hbr-*` images is a fast-follow — see the
hummingbird-bootc-robotics-images repo's README for the image build layout.

## Prerequisites

- OpenShift 4.x cluster
- `oc` and **helm** CLIs
- Quay.io account (images already pushed by the image-building repo)

## Sensitive / local files (gitignored)

| File | Purpose |
|---|---|
| `office/helm/values.yaml` | Image ref, pull secrets, resources |
| `hotel/helm/values.yaml` | Same pattern |
| `airport/helm/values.yaml` | Same pattern |
| `.env`, `.env.local` | General secrets |

Committed templates: `values.yaml.example` in each demo's `helm/` folder.

## How it works

| Concern | Approach |
|---|---|
| Image build | Not in this repo — see hummingbird-bootc-robotics-images |
| Image registry | Quay.io (`image.fullRef` in `values.yaml`) |
| OpenShift deploy | Helm chart per demo |
| Pull secrets | `pullSecret.name` in `values.yaml` → ServiceAccount |

## Adding a new demo

1. Build/push its image from the hummingbird-bootc-robotics-images repo
2. Create `<demo>/scripts/dispatch-task.sh`
3. Copy `office/helm/` → `<demo>/helm/`, update `values.yaml.example`
4. Copy `office/deploy-openshift.sh` → `<demo>/deploy-openshift.sh`

## Roadmap

| Phase | Goal | Status |
|---|---|---|
| **1** | Headless sim + logs + fleet monitor + patrol | Done |
| **2** | RMF Web dashboard (2D map, robots, tasks) | **Available** — `rmfWeb.enabled` |
| **3** | noVNC (Gazebo/RViz in browser) | **Available** — `novnc.enabled` |
| **4** | Migrate office demo to `hbr-*` (bootc-os) images | Done |
| **5** | Migrate hotel/airport demos to `hbr-*` images | Pending |

Both visualizations live in `common/helm/openrmf-lib/` and are wired in the office chart. Enable either or both in `values.yaml`.

See [office/README.md](office/README.md#3-view-the-demo) for browser URLs and verification.
