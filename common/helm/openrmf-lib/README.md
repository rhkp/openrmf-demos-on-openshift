# openrmf-lib — shared Helm library

Reusable templates for **RMF Web** (2D dashboard) and **noVNC** (Gazebo/RViz browser stream) across OpenRMF demos.

## Usage

Add as a Helm dependency in your demo chart:

```yaml
# <demo>/helm/Chart.yaml
dependencies:
  - name: openrmf-lib
    version: 0.1.0
    repository: file://../../common/helm/openrmf-lib
```

Then run `helm dependency update <demo>/helm` before install.

## Values (enable per demo)

```yaml
app:
  name: openrmf-office-demo   # Kubernetes labels

rmfWeb:
  enabled: true
  serverUri: ws://localhost:8000/_internal
  routes:
    clusterDomain: apps.example.openshift.com

novnc:
  enabled: true
  routes:
    clusterDomain: apps.example.openshift.com
```

## Templates to include

In your demo `templates/`:

| File | Include |
|---|---|
| `rmf-web-configmaps.yaml` | `{{ include "openrmf.lib.rmfWeb.configmaps" (list .) }}` |
| `rmf-web.yaml` | `{{ include "openrmf.lib.rmfWeb.manifests" (list .) }}` |
| `novnc.yaml` | `{{ include "openrmf.lib.novnc.manifests" (list .) }}` |
| `deployment.yaml` | volumes, initContainers, containers from `_rmf-web.tpl` / `_novnc.tpl` |

See [office/helm/templates/deployment.yaml](../../office/helm/templates/deployment.yaml) for the reference integration.

## Scripts (image)

| Script | Purpose |
|---|---|
| `common/scripts/launch-simulation.sh` | Headless Gazebo (default) |
| `common/scripts/launch-simulation-viz.sh` | Xvfb + x11vnc + Gazebo GUI for noVNC |

The demo image must include `xvfb`, `x11vnc`, and `x11-utils` (see `common/Dockerfile`).
