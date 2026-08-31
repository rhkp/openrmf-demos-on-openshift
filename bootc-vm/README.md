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

**Scope: office demo only**, core loop — simulation, fleet monitor, patrol
dispatch, zenoh router, noVNC viewer. The `rmf-web` dashboard (nginx +
websocket api-server bridge) is deliberately deferred, not silently dropped.

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
bootc host (Fedora-bootc, x86_64)
  systemd PID 1
  │
  ├─ rmf-zenoh-router.service   (Quadlet-bound container, starts first)
  ├─ rmf-simulation.service     (Gazebo + fleet adapters + Xvfb/x11vnc)
  ├─ rmf-fleet-monitor.service  (subscribes to /fleet_states)
  ├─ rmf-novnc.service          (websockify web viewer, port 8080)
  └─ rmf-task-dispatch.service  (submits the patrol once, then idles)
```

All five are ordinary systemd services generated from the `.container`
files in `containers/` by Quadlet — inspect/restart them with normal
`systemctl`/`journalctl` once the VM is up.

The host image itself (`Containerfile`) carries **no ROS, no GL, no
RoboStack** — it only registers the five Quadlet units and their bound
images under `/usr/lib/bootc/bound-images.d/`, exactly like
`images/ros-containers/Containerfile` does for its own ROS container.

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
`HOST_IMAGE=...`).

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

### 3. Launch the VM (a real EC2 instance)

```bash
./bootc-vm/scripts/register-and-launch.sh
```

Reuses the shared subnet/security group (`sg-...` only opens port 22) and
additionally creates one small, dedicated security group opening 8080 for
noVNC — additive, doesn't modify the shared one. No `KEY_NAME` needed (see
above); `INSTANCE_TYPE` defaults to `t3.medium`, bumped up from
`bootc-demos`' generic `t3.small` default since Gazebo/Nav2/RViz need more
headroom.

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

Gazebo/RViz render via Mesa software rendering (llvmpipe) — same rendering
path already proven in the noVNC deployment on OpenShift, just without GPU
passthrough (not needed for a demo VM).

## Status

- [x] Quadlet units written for all 5 services, reusing existing launch
      scripts/images unchanged
- [x] Host `Containerfile` written (Fedora-bootc + bound-image registration only)
- [x] Build/AMI/launch scripts written
- [x] Host image built + pushed
- [x] AMI built and registered
- [x] EC2 instance launched, all 5 systemd services `active (running)`,
      noVNC externally reachable (`HTTP 200` confirmed) — validated at
      parity with the OpenShift office demo
- [x] HTTPS added for noVNC (self-signed cert baked into the host image,
      confirmed via `curl -k` — TLS 1.3, `CN=rhkp-rmf-office-bootc-vm`)
- [x] Rebuilt + relaunched with HTTPS + `rhkp-` naming
      (AMI `ami-0b218d07bfe70899c`, instance `i-03eb13fddd4a3c4ea`); old
      unprefixed instance/AMI/snapshot/security-group cleaned up
- [ ] `rmf-web` dashboard (deferred — future phase, not in scope here)
- [ ] Optional: `NOPASSWD` sudoers rule for the baked-in `admin` user (not
      needed so far — `systemctl status`/`journalctl` reads work without
      root; only needed if interactive admin access is required later)

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
