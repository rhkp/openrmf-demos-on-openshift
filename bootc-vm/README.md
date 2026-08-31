# bootc host image + VM (office demo)

Goal: run the office demo (`collision_test.world` — table/sofa/chair room, 4
robots) on a real bootable bootc **host** (own kernel, systemd PID 1),
booted as an actual VM (an EC2 instance), instead of an OpenShift Pod.

This directory is fully isolated from `office/`, `common/`, `bootc/`,
`hummingbird/` — nothing outside `bootc-vm/` is modified by this work.

## Why this is a different thing from `bootc/` and `hummingbird/`

Those two branches used a bootc image only as a base for an OpenShift Pod —
never its actual host-management features (no `bootc upgrade`, no systemd
PID 1, no Quadlet). Because a Pod can't run ROS2 in its own bound container,
they had to rebuild all of RMF from source against RoboStack/conda just to
get ROS2 onto a dnf-based (Fedora/CentOS) base — a large effort (GCC
pinning, websocketpp/asio patches, fiona exclusion; see
`hummingbird/README.md`).

Here the host is an actual bootc-managed OS, so the ROS/RMF workload can run
in its **own bound container** instead, started via
[Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
(Podman's systemd generator) — the exact pattern used in
`~/projects/bootc-images/images/ros-containers`. That means the bound image
can just be the already-proven, already-deployed
`quay.io/rhkp/openrmf-openshift-office-demo:nav2-sensors`
(Ubuntu/apt, built from `common/Dockerfile`, currently running on
OpenShift) **completely unchanged** — zero RoboStack, zero source patches.

Bonus: this whole demo is one VM with every container on `Network=host`, so
`zenoh-router`/`simulation`/`novnc` just talk over `localhost` — no
cross-Pod `zenohd` startup race to design around (the OpenShift version
needed launch-script retry loops for exactly this; those fixes still ship
inside the image unchanged, they just don't need to work as hard here).

**Scope: office demo only.** The `rmf-web` dashboard (nginx + websocket
api-server bridge) is deliberately deferred, not silently dropped.

## The custom world, not the stock one

An earlier version of this deployment ran `RMF_LAUNCH_FILE=office.launch.xml`
— which is the **stock, unmodified upstream `rmf_demos_gz` office world**,
not the custom "simple room" (table/sofa/chair, 4 `tinyRobot`s) this
project actually built. Confirmed directly: `office.launch.xml` is
unmodified upstream inside the image. The custom world
(`collision_test.world`) only exists behind the **"robot-as-pod"
architecture** (`office/helm/templates/robot-deployments.yaml`,
`ROBOT-AS-POD-IMPLEMENTATION.md`) — `office/helm/values.yaml`'s
`robots.enabled: true` confirms that split architecture is the actual
current production setup, not the simpler single-container mode. This
deployment now replicates that split, one Quadlet unit per what would be a
separate Pod on OpenShift.

**Script drift, found by diffing directly.** `office/helm/files/` (Helm
ConfigMap-mounted, always wins over what's baked into the image) has
diverged from `common/scripts/` baked into
`quay.io/rhkp/openrmf-openshift-office-demo:nav2-sensors`:
- `launch-robot.sh`: **substantially different**. The image-baked version
  spawns its own per-robot fleet adapter; the real (Helm) version doesn't
  — fleet adaptation is centralized in the simulation container instead.
  Using the stale baked version would run duplicate/conflicting fleet
  adapters.
- `wait-for-world.sh`: Helm version additionally waits for `/tf`+`/tf_static`.
- `launch-simulation-world-only-viz.sh`: **not in the image at all**.
- `ros-env.sh`, `launch-fleet-coordinator.sh`, `fleet-coordinator.py`:
  confirmed identical — no override needed for these.

The 3 diverged files are copied verbatim into `scripts-overlay/` (sourced
from `office/helm/files/`, the proven versions) and baked into the host
image at `/opt/rmf-overlay/`, then `Volume=`-mounted over the stale/missing
paths in the relevant Quadlet units — the same override mechanism Helm's
ConfigMap achieves on OpenShift, just via the bootc host instead.

## GPU is required, not optional

`launch-simulation-world-only-viz.sh` explicitly unsets `DISPLAY` so
Gazebo's `gpu_lidar` sensor uses EGL+NVIDIA GPU rendering. Per this
project's own prior debugging: *gpu_lidar render-to-texture silently
produces no data on software rendering.* Without a real GPU, robots would
get empty lidar scans — Nav2/SLAM/collision-avoidance wouldn't actually
work even though every service would still show `active`. This is why the
instance type is a GPU instance (`g5.2xlarge`, 1x A10G), matching
OpenShift's own GPU-node rendering path, not a CPU-only guess.

**Split build-time vs. boot-time, out of necessity:**
- The NVIDIA **kernel module** must be built at *image-build* time
  (`Containerfile`, via RPM Fusion's `akmod-nvidia`) — bootc images are
  immutable at runtime (`/usr` read-only after boot), so akmod's normal
  "rebuild automatically after a kernel update" model doesn't apply; the
  module has to already match the image's baked kernel before first boot.
  Kernel version is pinned from `/usr/lib/modules/*`'s directory name (the
  base image's own kernel), not the build host's `uname -r` — the build VM
  and the target bootc image run different kernels entirely.
- The **CDI device spec** (`nvidia-ctk cdi generate`, referenced by
  Quadlet's `AddDevice=nvidia.com/gpu=all`) needs *live GPU hardware* to
  query — which the CPU-only build VM doesn't have. This runs instead as a
  plain systemd unit (`nvidia-cdi-generate.service` — **not** Quadlet,
  since Quadlet only generates units for a Podman container, and this is a
  bare host command) at every boot on the real GPU instance.

This is meaningfully higher-risk than everything else in this deployment
— kernel-version matching, whether RPM Fusion's standard driver works
correctly on G5's A10G passthrough vs. needing AWS's own GRID drivers, CDI/
Podman version interactions. Expect iteration on real hardware, the same
way the AMI-build issues were worked through earlier.

**First real-hardware finding: the module builds but never loads.**
Confirmed on the actual `g5.2xlarge`: `lspci` showed the A10G detected,
`modinfo`/`find` confirmed the built kernel module files matched the
running kernel exactly — but `lsmod` showed nothing loaded, and
`/etc/modules-load.d/` was completely empty. RPM Fusion's `akmod-nvidia`
builds the module and relies on the same on-demand udev/`nvidia-modprobe`
trigger a desktop's Xorg/Wayland session would normally fire on first
touch of `/dev/nvidia0` — a headless server never does that, so nothing
ever loads it. Fixed by explicitly listing the modules
(`nvidia nvidia_uvm nvidia_modeset nvidia_drm`) in
`/etc/modules-load.d/nvidia.conf`, baked at build time — the standard
fix for headless/compute NVIDIA servers. `nvidia-cdi-generate.service`
now also explicitly orders `After=systemd-modules-load.service`.

Also added while debugging this on real hardware: a `NOPASSWD` sudoers
rule for `admin` (`/etc/sudoers.d/90-admin-nopasswd`) — the baked-in user
has a key but no password, so `sudo` always failed asking for one that
doesn't exist, which blocked live diagnosis (`sudo modprobe`, `sudo podman
exec`, etc.) without a full rebuild each time. Acceptable tradeoff for a
single-purpose demo VM, not a shared multi-tenant host.

## Architecture: why this all runs on x86_64, not the Mac

`docker.io/osrf/ros:jazzy-desktop` — the base `common/Dockerfile` (and so
`nav2-sensors`) is built from — is published **amd64-only** (confirmed via
the Docker Hub API, no arm64 manifest exists). So none of this can run
natively on an Apple Silicon Mac; it has to be built and run on x86_64.

The existing AWS build VM (x86_64, per project memory) is the right place
for all of it. Note: **no "Podman Desktop" (the GUI app) is needed anywhere,
on the build VM or otherwise** — `bootc-image-builder` is just a privileged
`podman run` invocation; the plain CLI already on that VM is sufficient.

## How it works

```
bootc host (Fedora-bootc, x86_64, NVIDIA driver baked in)
  systemd PID 1
  │
  ├─ nvidia-cdi-generate.service     (plain systemd unit, not Quadlet — runs first)
  ├─ rmf-zenoh-router.service        (Quadlet-bound container, starts first among the RMF units)
  ├─ rmf-simulation.service          (Gazebo world + fleet adapter + fleet manager + Xvfb/x11vnc, GPU)
  ├─ rmf-fleet-coordinator.service   (centralized task assignment)
  ├─ rmf-robot-tinyRobot1.service    (Nav2 + SLAM for tinyRobot1)
  ├─ rmf-robot-tinyRobot2.service    (Nav2 + SLAM for tinyRobot2)
  ├─ rmf-robot-tinyRobot3.service    (Nav2 + SLAM for tinyRobot3)
  ├─ rmf-robot-tinyRobot4.service    (Nav2 + SLAM for tinyRobot4)
  ├─ rmf-fleet-monitor.service       (subscribes to /fleet_states)
  ├─ rmf-novnc.service               (websockify web viewer, port 8080)
  └─ rmf-task-dispatch.service       (submits the patrol once, then idles)
```

All except `nvidia-cdi-generate.service` are ordinary systemd services
generated from the `.container` files in `containers/` by Quadlet —
inspect/restart them with normal `systemctl`/`journalctl` once the VM is
up. Each robot maps to what would be its own separate Pod on OpenShift
(`office/helm/templates/robot-deployments.yaml`) — same split, just
Quadlet units instead of Kubernetes Pods, all sharing the host's real
network via `Network=host` instead of per-Pod Services.

The host image (`Containerfile`) carries **no RoboStack, no source
builds** — the RMF/ROS workload is entirely in the bound app image,
unchanged. It does now carry the NVIDIA driver + `nvidia-container-toolkit`
(see "GPU is required, not optional" above) — the one exception to "host
stays minimal," because `gpu_lidar` genuinely needs it.

**No Quadlet `.pod` file needed.** Every zenoh config/launch script in this
repo explicitly disables multicast scouting
(`scouting/multicast/enabled=false`) and connects via a static
`tcp/localhost:7447` endpoint instead — there's no namespace-scoped
discovery anywhere for a `.pod`'s shared netns to help with. `Network=host`
on each independent `.container` unit gives all five the same real
loopback, which is a strict superset of what a `.pod` would provide.

**Firewalld: checked, not applicable here.** `Network=host` means these
containers bind the host's real interface directly, so Podman's usual
automatic firewall punching (which only applies to bridge networking +
`PublishPort=`) wouldn't help if a host firewall were active. Verified
directly against the base image (`rpm -q firewalld` inside
`quay.io/fedora/fedora-bootc:43`) that firewalld **isn't installed** on this
base at all, so there's nothing to configure — the EC2 security group
(`scripts/register-and-launch.sh`) is the only access-control layer for
22/8080, which is fine for a demo VM. Re-check this if the base image ever
changes.

## Naming convention

Every AWS resource this creates (AMI, EC2 instance Name tag, the dedicated
noVNC security group) is prefixed `rhkp-` so it's easy to find/filter in a
shared account alongside everything else already prefixed that way
(`rhkp-bootc-demo-staging` bucket, `rhkp-aws.pem` key, etc.). The quay.io
host image already lives under the `quay.io/rhkp/` namespace, so no change
needed there.

## Building and running

### 1. Build the host image (on the AWS build VM)

```bash
./bootc-vm/scripts/build-host-image.sh
```

Pushes `quay.io/rhkp/openrmf-office-bootc-host:latest` (override via
`HOST_IMAGE=...`). Now includes compiling the NVIDIA kernel module —
expect a noticeably longer build than before.

### 2. Build and register the AMI

Reuses the S3 bucket, region, subnet, and base security group already
provisioned and working for `~/bootc-demos` in this AWS account (found in
that repo's gitignored `common/env` on the build VM) rather than
provisioning new ones — same account, same `vmimport` role already set up
there.

Credentials: the build VM has no `~/.aws` — it authenticates via its EC2
instance role over IMDS instead, which `build-ami.sh` detects automatically
(falls back to `--network host` for the builder container so it can reach
the metadata endpoint; matches `bootc-demos`' own proven
`demos/05-create-ami-deploy-ec2/run.sh` pattern exactly rather than
reinventing it).

`config.toml` already has a real SSH public key baked in (no EC2 key pair
needed — fedora-bootc has no cloud-init, so key-pair injection wouldn't work
anyway, same reasoning `bootc-demos` bakes its own demo user).

```bash
./bootc-vm/scripts/build-ami.sh
```

This builds *and* uploads *and* registers the AMI in one step —
`bootc-image-builder`'s `--aws-*` flags do the full pipeline, no manual
`import-snapshot`/`register-image` needed.

Three gotchas hit and fixed while first running this (all now handled by the
script, documented here so they aren't rediscovered):
- **`fedora-bootc` has no default root filesystem type** (unlike
  `centos-bootc`/`rhel-bootc`) — `bib` fails with `missing required info:
  DefaultRootFs` without an explicit `--rootfs` flag (`ROOTFS=xfs` by
  default, overridable).
- **`bib` no longer pulls images itself** — it needs `HOST_IMAGE` already
  present in *root's* podman storage before it runs (the script does this
  pull explicitly now). Root's podman is a separate auth/storage namespace
  from the invoking user's rootless podman, so if `HOST_IMAGE` is private,
  root also needs its own quay.io login — e.g. copy the working rootless
  auth over once: `sudo cp /run/user/$(id -u)/containers/auth.json
  /root/.config/containers/auth.json`.
- **Stale lock state from an interrupted `bib` run** can surface as
  `acquiring lock N for container/volume ...: file exists` on a later
  attempt even though `podman ps -a`/`volume ls` show nothing — fix with
  `sudo podman system renumber` (safe; doesn't touch existing images).
- **Logically bound images (the Quadlet units' `Image=` values) must already
  be in root's default container store before `bootc install` runs** —
  bootc copies them in from there at install time, it does not fetch them
  itself (confirmed by a real failure: `resolving bound image ...: does not
  resolve to an image ID`, since `bib`'s internal `bootc install` runs with
  `--skip-fetch-check`, disabling network fallback). `build-ami.sh` now
  pulls every bound image's `Image=` value, not just `HOST_IMAGE`, before
  invoking `bib`.
- **Default root partition size is nowhere near enough.** The bound images
  installed alongside the host OS add up fast (`nav2-sensors` alone is
  6.76 GB) — confirmed by a real `no space left on device` failure mid-install.
  `config.toml` now sets `[[customizations.filesystem]] mountpoint = "/"
  minsize = "30 GiB"`.
- **AMI names must be unique per account/region — rebuilding under the same
  name fails at the very last step**, after the full disk build + S3 upload
  + snapshot import already completed (hit this twice). `build-ami.sh` now
  deregisters any prior AMI/snapshot under `AWS_AMI_NAME` up front instead
  of wasting a full ~25-30 min cycle to find out at the end.
- **Overlay scripts (`scripts-overlay/`) need their executable bit set
  explicitly, not inherited from the source.** `cp`-ing from
  `office/helm/files/` preserved those files' actual git permissions
  (`rw-r--r--`, not executable) — Helm's ConfigMap mount papers over this
  with its own `defaultMode: 0755`, but a plain Podman bind mount
  (`Volume=...:ro`) uses the host file's real mode directly. Confirmed by a
  real failure: both `rmf-simulation` and every robot unit exited
  `status=126` / `Permission denied` running their (correctly-pathed, but
  non-executable) overlay script. Fixed both at the source
  (`chmod +x scripts-overlay/*.sh`) and defensively in the `Containerfile`
  (`RUN chmod +x /opt/rmf-overlay/*.sh`) so this can't regress silently.
- **NVIDIA driver builds fine but never loads on a headless server.**
  Confirmed on real `g5.2xlarge` hardware: PCI device detected, kernel
  module files built and matching the running kernel, but `lsmod` showed
  nothing loaded — a desktop's Xorg/Wayland session is normally what
  triggers the on-demand udev/`nvidia-modprobe` load, and headless servers
  never do that. Fixed via `/etc/modules-load.d/nvidia.conf`
  (`nvidia nvidia_uvm nvidia_modeset nvidia_drm`).
- **`dnf install kernel-devel` (unpinned) can silently upgrade — and
  remove — the running kernel** as a side effect of dependency resolution
  (confirmed in a build log: `Removing kernel-core-0:7.1.10...`, installing
  `7.1.12` instead). A kernel-version variable captured *before* this
  install is stale immediately after. Pinning the exact pre-install NVR
  (`kernel-devel-<version>`) isn't robust either — that exact build can be
  pruned from Fedora's mirrors by the time of a later rebuild (confirmed:
  worked once, then `No match for argument` a few hours later). The robust
  approach: let the upgrade happen, then read the kernel version from
  `/usr/lib/modules/*` *after* installing — that's the only point it's
  ground truth.

### 3. Launch the VM (a real EC2 instance)

```bash
./bootc-vm/scripts/register-and-launch.sh
```

Reuses the shared subnet/security group (`sg-...` only opens port 22) and
additionally creates one small, dedicated security group opening 8080 for
noVNC — additive, doesn't modify the shared one. No `KEY_NAME` needed (see
above); `INSTANCE_TYPE` defaults to `g5.2xlarge` (1x A10G GPU) — required
for `gpu_lidar`, not just extra headroom (see "GPU is required, not
optional" above).

Prints the instance's public IP, SSH command, and demo URL.

No local QEMU/KVM and no nested virtualization anywhere in this flow — disk
assembly doesn't need hardware acceleration, and AWS's own Nitro hypervisor
does the actual VM boot.

### 4. View the demo

```
https://<public-ip>:8080/vnc.html
```

noVNC is served over TLS via a self-signed cert baked into the host image
(`Containerfile` generates it with `openssl req -x509 ...`, mounted into the
`rmf-novnc` container and passed to `websockify --cert=...`). There's no
fixed domain or Elastic IP for this demo VM (the public IP changes per
launch), so a real Let's Encrypt-style cert isn't practical — **your browser
will show a "not trusted" warning; click through it** (Advanced → Proceed).
noVNC's own client JS auto-selects `wss://` when the page itself loads over
`https://`, so no separate app-level config is needed beyond serving the
page itself over TLS.

Gazebo's GUI/RViz still render via Mesa software rendering (llvmpipe) on
the VNC display — only `gpu_lidar`'s own sensor rendering needs the real
GPU (via EGL, `DISPLAY` unset in the headless server process).

## Status

- [x] Quadlet units + host image working end-to-end for the **stock**
      office world (single-container mode): AMI `ami-0b218d07bfe70899c`,
      instance `i-03eb13fddd4a3c4ea`, HTTPS confirmed
- [x] Switched to the real custom demo: `collision_test.world` +
      robot-as-pod architecture (10 units: zenoh-router, simulation,
      fleet-coordinator, 4x robot, fleet-monitor, novnc, task-dispatch)
- [x] Script-drift found and fixed via `scripts-overlay/` +
      Quadlet `Volume=` mounts (`launch-robot.sh`,
      `launch-simulation-world-only-viz.sh`, `wait-for-world.sh`)
- [x] NVIDIA driver + CDI support added (`Containerfile` akmod build +
      `nvidia-cdi-generate.service` + `AddDevice=nvidia.com/gpu=all` on
      `rmf-simulation`); `INSTANCE_TYPE` → `g5.2xlarge`
- [x] First `g5.2xlarge` boot: driver built but never loaded (headless,
      no udev trigger) — fixed via `/etc/modules-load.d/nvidia.conf`;
      also added `NOPASSWD` sudo for `admin` for faster live debugging
- [x] Found + fixed a second real bug on the next rebuild: overlay scripts
      (`scripts-overlay/*.sh`) weren't executable (`cp` preserved
      non-executable git permissions) — both `rmf-simulation` and every
      robot unit were exiting `status=126`/`Permission denied`. Fixed at
      the source and defensively in the `Containerfile`.
      Also hardened `build-ami.sh` to auto-deregister a prior AMI under
      the same name (hit the `InvalidAMIName.Duplicate` failure twice).
- [x] **All 11 units `active` on real `g5.2xlarge` hardware**
      (AMI `ami-02ae3f13f03518c12`, instance `i-0a952a1baee120969`).
      `nvidia-cdi-generate` succeeded, `lsmod` confirms the driver loaded.
      `nvidia-smi` binary itself still missing (cosmetic — NVML/the actual
      driver path CDI depends on works regardless; not blocking).
- [x] **`gpu_lidar` confirmed producing real scan data** —
      `ros2 topic echo /tinyRobot1/scan --once` returned real, varying
      range values (~0.8m–6m+), not empty/all-zero/all-`inf`. This was the
      core risk flagged at the start of the GPU work; now resolved.
- [ ] `rmf-web` dashboard (deferred — future phase, not in scope here)

## Troubleshooting

- `systemctl status rmf-simulation` / `journalctl -u rmf-simulation -f` —
  same log signature as the OpenShift `simulation` container; a crash loop
  here means check the same things (missing `requests` pip package class of
  bug, zenoh registration race) documented in project memory for the other
  branches — nothing new should be introduced by running on a bootc host
  instead of a Pod, since it's the identical container image.
- If `rmf-novnc` can't reach the VNC port: confirm both units show
  `Network=host` — noVNC's `websockify` is hardcoded to connect to
  `127.0.0.1:5900`, which only resolves to the simulation container's port
  if they share the host network namespace (true here, same as within a
  single OpenShift Pod).
- `nvidia-smi` on the host confirms the driver loaded; `systemctl status
  nvidia-cdi-generate` and `cat /var/run/cdi/nvidia.yaml` confirm the CDI
  spec exists before `rmf-simulation` starts (it `Requires=`/`After=` this
  unit, so it shouldn't start without it — if it does, the dependency
  didn't take, check the unit file was actually copied/enabled at build
  time via `systemctl is-enabled nvidia-cdi-generate`).
- If `rmf-simulation` starts but `AddDevice=nvidia.com/gpu=all` silently
  has no effect (no GPU visible inside the container): check
  `/var/run/cdi/nvidia.yaml` isn't empty/stale — it's regenerated fresh
  every boot specifically to avoid this, so an empty file usually means
  `nvidia-ctk` itself failed (check `journalctl -u nvidia-cdi-generate` —
  most likely cause is the driver/module not actually loaded, i.e.
  `nvidia-smi` failing).
- The concrete test that GPU rendering is actually feeding lidar, not just
  that nothing crashed: `ros2 topic echo /tinyRobot1/scan --once` from
  inside `rmf-simulation` or a robot container should show real,
  non-empty/non-all-`inf` range data.
- If `launch-robot.sh`/`launch-simulation-world-only-viz.sh` behave
  differently than expected: confirm the overlay actually took effect —
  `podman inspect rmf-robot-tinyRobot1 --format '{{.Mounts}}'` should show
  the `/opt/rmf-overlay/...` bind mount; if a robot spawns its own fleet
  adapter (duplicate, conflicting with the one in `rmf-simulation`), the
  stale image-baked script is running instead of the overlay.
