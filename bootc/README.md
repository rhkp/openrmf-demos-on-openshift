# Bootc migration (office demo)

Goal: run the office demo (`collision_test.world` — table/sofa/chair room, 4 robots)
from a bootc image instead of the current Ubuntu/apt-based `common/Dockerfile`,
with zero regressions in collision avoidance, RViz visuals, patrol dispatch, or
the dashboard/noVNC.

This directory is fully isolated from `common/`, `office/helm/`, etc. — nothing
outside `bootc/` is modified by this work. See the plan for full context and
rationale: `.claude/plans/valiant-sauteeing-sunrise.md` (this session's plan file).

## Why not just swap the Dockerfile's `FROM` line?

Bootc base images are Fedora/CentOS/RHEL (dnf-based). ROS2 Jazzy's official
binaries are Ubuntu/apt-only. So this isn't a drop-in base swap — ROS2 itself
has to come from somewhere else: [RoboStack](https://robostack.github.io/)
packages ROS2 Jazzy (including Gazebo Harmonic integration, Nav2, slam_toolbox)
via conda/pixi, distro-independent. Open-RMF's own packages (`rmf_demos`,
`rmf_fleet_adapter`, etc.) aren't on any conda channel — those still get
`colcon build`'d from source on top of the ROS2 env, exactly like today.

Reference precedent: `github.com/RHEcosystemAppEng/rhoim-bootc-images` (a bootc
vLLM inference image). Their OpenShift deployment runs the bootc image as an
ordinary Deployment — no `--privileged`, no systemd PID1, no VM — just
`command:` overriding the default `/sbin/init`. Same pattern our Helm charts
already use, so no Helm/OpenShift changes are needed here, only the image.

## Status

- [x] Spike: RoboStack ROS2 Jazzy + Gazebo + Nav2 + slam_toolbox + `rmw_zenoh_cpp`
      resolve and run on `centos-bootc:stream9` (`scripts/spike.Containerfile`)
- [x] `rmf_demos` builds from source against the RoboStack env — all 54
      workspace packages build clean (`rmf_demos_maps` /
      `rmf_traffic_editor_test_maps` are deliberately excluded via
      `COLCON_IGNORE`, see the fiona note in `Containerfile`; this means
      airport/hotel stock maps aren't available in this image yet, only the
      office demo's custom `collision_test.world`)
- [x] Full `bootc/Containerfile` written (multi-stage: RoboStack builder +
      slim runtime) — TinyRobot models, RViz Mesa shader patch, custom
      launch/config/scripts/worlds, non-root UID 1001, all folded in
- [ ] Image built + pushed — `bootc/office-values.yaml` created, points at
      `quay.io/rhkp/openrmf-openshift-office-demo:bootc-fedora`
- [ ] Deployed to OpenShift, validated at parity with the `main`-based office demo

Every repo pulled from source (`rmf_demos`, `rmf.repos`'s ~17 packages,
`ament_cmake`, `m-explore-ros2`) is pinned to a specific commit SHA — upstream
`rmf.repos` itself only ever points at floating `main`/`master` branches, so
without pinning a routine rebuild could silently pull different, possibly
incompatible commits. Pins live in the `Containerfile` (rmf_demos,
ament_cmake, m-explore-ros2) and `scripts/filter-rmf-repos.py` (everything
`rmf.repos` pulls in) — update them deliberately when moving to newer
upstream commits, not as a side effect of an unrelated change.

## Building the full image

Run on the build VM (podman, not locally — see project memory on podman
stability):

```bash
podman build -f bootc/Containerfile -t quay.io/rhkp/openrmf-openshift-office-demo:bootc-fedora .
```

Deploy with the existing, unmodified `office/helm` chart pointed at this
image's values file instead of the default:

```bash
VALUES_FILE=bootc/office-values.yaml ./office/deploy-openshift.sh
```

(`bootc/office-values.yaml` uses a distinct `fullnameOverride` —
`rmf-office-demo-bootc` — so it can run side by side with the existing
`main`-based deployment in the same namespace for direct comparison.)

## Building the spike

`scripts/spike.Containerfile` was the throwaway proving ground for the two
biggest open risks (Zenoh middleware availability, RoboStack+Gazebo actually
running on a bootc/CentOS base) and for working out the colcon/GCC-14 fixes
now folded into `Containerfile` above. Kept for reference/future spikes, not
part of the real build:

```bash
podman build -f bootc/scripts/spike.Containerfile -t spike-bootc-robostack .
```
