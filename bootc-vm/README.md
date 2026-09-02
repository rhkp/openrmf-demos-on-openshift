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

## Host base image: Hummingbird, not fedora-bootc

The host now builds `FROM quay.io/hummingbird-community/bootc-os:latest`
instead of `quay.io/fedora/fedora-bootc:43` — Project Hummingbird's
hardened, mostly-rebuilt (`.hum1`) package base, matching the hardening
rationale already established for the separate `hummingbird/` app-image
effort in this repo. Hard replacement, not a build-arg choice — same
pattern `hummingbird/` used for the app image (contrast with
`~/projects/bootc-images/images/ros-containers`, which *does* parameterize
base OS via a build arg — not the pattern here, since this is a migration,
not offering a choice).

This was verified hands-on against the real image (disposable `podman run`
containers, zero AWS cost) before touching the Containerfile, given how
much iteration the NVIDIA work already took. Confirmed directly: the
kernel NVR is identical to fedora-bootc's (`7.1.10-100.fc43.x86_64`, no
`.hum1` suffix — unlike podman/curl/sudo/firewalld, which are all
Hummingbird-rebuilt), so the existing "capture kernel version after
installing kernel-devel, not before" logic transfers unchanged. Also
confirmed directly: the Quadlet generator is present and correctly wired
(`podman-system-generator -> .../podman/quadlet`) — the architecture's
foundation isn't just inferred from the podman version.

Two genuinely new failure modes surfaced that the existing `hummingbird/`
effort never hit (it uses RoboStack/conda, never RPM Fusion):

- **RPM Fusion's own bundled repo files break under Hummingbird.**
  `/etc/os-release`'s `VERSION_ID` is a date string (`20251124`), not a
  Fedora release number — breaks any repo using `$releasever` in its
  baseurl/metalink, including repo files installed via the
  `rpmfusion-*-release` RPM itself (not something we write ourselves).
  Confirmed via a real 404 on RPM Fusion's metalink endpoint requesting
  `...-20251124...`. `hummingbird/Containerfile`'s own fix for this class
  of problem (hardcoding "43" into one hand-written repo file) doesn't
  cover repo files bundled inside RPMs we don't control. Fixed instead
  with a global override — `RUN echo 43 > /etc/dnf/vars/releasever` —
  before any repo is touched; fixes every repo at once (Hummingbird's own
  repo doesn't use `$releasever`, so it's unaffected).
- **Installing the RPM Fusion release RPMs via `dnf install <url>`
  conflicts with the already-installed `hummingbird-release` package**
  (both provide `system-release`; dnf's solver tries to swap in a
  `fedora-release-*` variant and collides). Tried excluding the
  conflicting package name — whack-a-mole, doesn't converge (excluding one
  spin variant just surfaces the next: `fedora-release-budgie`,
  `-sway-atomic`, etc.). Fixed by installing the release RPMs via `rpm -Uvh
  --nodeps --nosignature` instead — bypasses dnf's full dependency/conflict
  solver for these (release RPMs are dependency-light by design: just repo
  files + GPG keys). Normal `dnf install` of actual packages afterward
  still verifies against the keys correctly, since the RPM's payload
  (including the GPG key files) installs regardless of `--nosignature`
  (that flag only skips checking the release RPM's *own* signature).

Two smaller, already-anticipated differences also confirmed directly:
`openssl` isn't installed by default on Hummingbird (fedora-bootc has it)
— resolves fine from Hummingbird's own catalog once requested explicitly,
no fallback-repo dependency. `firewalld` **is** installed and enabled by
default on Hummingbird (fedora-bootc has neither) — the
`firewall-offline-cmd` step this README used to describe as dead code for
fedora-bootc is now active and required.

**A third, much deeper problem, found on real hardware: a genuine kernel
panic.** `bootc-image-builder` also needed `ROOTFS=ext4` instead of `xfs`
on this base — `xfsprogs` genuinely isn't installed anywhere in the
Hummingbird image (confirmed via `rpm -q`; `e2fsprogs` is present), and
osbuild's `mkfs.xfs` stage needs that tool present in the source image
itself, not just its own buildroot (isolated cheaply via a local
`--type qcow2` test before ever touching AWS). But fixing that only got
further: the launched instance kernel-panicked on boot —
`VFS: Unable to mount root fs on unknown-block(0,0)`. Root cause: the
mandatory kernel upgrade (`dnf install kernel-devel` dragging
`kernel`/`kernel-core` along, since no `kernel-devel` exists anywhere
matching Hummingbird's original kernel — confirmed via a hard dnf
resolution failure when trying to protect/exclude the original kernel
packages from upgrading) leaves the **new** kernel with no initramfs at
all. The kernel-core package's own post-install hook tries to generate one
via the normal kernel-install chain, but that chain assumes a live booted
system — confirmed in the build log: `grub2-probe: error: failed to get
canonical path of 'overlay'`, `System has not been booted with systemd as
init system` — and fails silently inside a `podman build` sandbox instead
of deferring cleanly to bootc, unlike Fedora's own rpm-ostree-aware
kernel-install hook (which exits 77 *on purpose* — confirmed working
correctly on fedora-bootc, where this was never a problem). Fixed by
generating the initramfs explicitly ourselves:
`dracut --force --no-hostonly`, matching this image's own
`/usr/lib/dracut/dracut.conf.d/20-bootc.conf` (`hostonly=no`) setting for
portability to real hardware. Confirmed directly before spending another
AMI cycle: without this, `initramfs.img` is simply absent for the new
kernel; with it, a normal ~54MB image containing the `nvme` driver (and
everything else needed to actually boot on EC2) is produced.

**A fourth problem, the sneakiest one: the NVIDIA module was never actually
built, and nothing said so.** After the boot panic was fixed, the instance
came up fine but `nvidia-cdi-generate` failed — `modinfo nvidia` couldn't
find the module at all, and `rpm -qa` showed no `kmod-nvidia-*` package
had ever been produced. Traced back through the build logs (the actual
`akmods` step had been cached across three rebuilds, so its real output
was buried): `Building and installing nvidia-kmod [FAILED]` — with a real
compile-time error, `error creating temporary file /var/tmp/rpm-tmp...:
Permission denied`. Root cause: **`/var/tmp` genuinely doesn't exist on
Hummingbird at all** (confirmed: `ls -ld /var/tmp` → "No such file or
directory" — `/tmp` is fine, `/var/tmp` just isn't there), and
`akmodsbuild` (which shells out to `rpmbuild`) needs it for staging. Worse:
**`akmods --force` exits `0` even when the compile fails** — it logs
"Building rpms failed" as a hint, not an error, so `podman build` never
noticed and the image built and pushed "successfully" with a genuinely
missing driver, three rebuild cycles running before this surfaced. Fixed
two ways: `mkdir -p /var/tmp && chmod 1777 /var/tmp` before the
kernel-devel/akmod-nvidia install (confirmed this alone fixes the build,
verified locally — `nvidia.ko.xz` appears where it didn't before), and an
explicit post-build check (`ls .../nvidia.ko.xz || exit 1`) so a build
failure here can never again slip through silently — `akmods`'s own exit
code cannot be trusted alone.

## End-to-end reliability: three more bugs found chasing real task dispatch

The GPU/driver work above got `gpu_lidar` producing real scan data, but a
completely fresh, unmodified boot still didn't reliably reach "4 robots
actually patrol the building" — three more real, previously-undiagnosed
bugs surfaced closing that gap, none of them GPU-related.

- **firewalld's default zone silently broke Gazebo's own transport, not
  just our app ports.** Even with 7447/5900/8080 open, `gz topic -l`
  inside `rmf-simulation` returned *nothing at all* — not even the
  always-on `/clock`/`/stats` topics — meaning `gpu_lidar`'s scan topic
  had zero subscribers reaching it. Root cause: Gazebo's own transport
  (`gz-transport`) uses UDP multicast discovery (port 11319) plus
  per-topic ephemeral TCP data channels that can't be allowlisted by a
  fixed port range; firewalld's default zone was dropping both. Confirmed
  directly: opening `11319/udp` alone wasn't sufficient; switching the
  default zone to `trusted` fixed it immediately. Safe here specifically
  because every `.container` unit uses `Network=host` — there's no
  container-to-container boundary for the OS firewall to usefully enforce,
  and the real security boundary is the AWS Security Group. Fixed via a
  second `firewall-offline-cmd --set-default-zone=trusted` call (it's a
  "stand-alone option" per its own usage rules — confirmed by a real
  failure combining it with `--add-port` in one invocation).
- **What looked like a cold-start "zenoh registration race" for the
  traffic schedule node was actually a missing file.** The script's own
  comments (and this README, previously) described `wait-for-service.sh`
  timing out under cold-start CPU pressure as an already-known,
  hard-to-avoid race. It wasn't a race at all: `wait-for-service.sh`
  exists in `common/scripts/` in this repo, but the already-built,
  already-tagged `quay.io/rhkp/openrmf-openshift-office-demo:nav2-sensors`
  image predates that file being added — every retry attempt failed
  near-instantly (exec of a nonexistent file), 100% reproducible across
  three full container restarts, not intermittent at all. Fixed by
  rebuilding and re-pushing the same app image tag. Confirmed: the
  schedule node now registers in ~6 seconds on the first attempt,
  consistently. (Also bumped the retry budget 3→6 attempts and made total
  exhaustion fatal — `exit 1`, relying on `Restart=always` on
  `rmf-simulation.service` for a clean restart — as defense-in-depth, even
  though the real fix above made this mostly moot.)
- **Plain `kill` (SIGTERM) doesn't reliably stop a failed retry attempt,
  causing duplicate fleet adapters that crash each other.** Confirmed on
  real hardware via `ps`: after the fleet-adapter retry loop declared an
  attempt "failed" and moved on, the "failed" process was still alive
  minutes later, running *alongside* the new attempt. Both processes then
  raced to register the identical ROS node name
  (`tinyRobot_fleet_adapter`); whichever finished second crashed with
  `AssertionError: Unable to initialize fleet adapter. Please ensure RMF
  Schedule Node is running` — even though the schedule node was directly
  confirmed alive and actively processing at that exact moment. Root
  cause: an rclpy-based process deep in native (rclcpp/zenoh)
  initialization when SIGTERM arrives can go a long time without actually
  dying, since Python's signal handling only runs between bytecode
  instructions on the main thread and won't interrupt a blocking
  C-extension call. Fixed with a shared `kill_and_confirm_dead()` helper
  (SIGKILL, which can't be caught or deferred, then polls for the pid to
  actually disappear) used by both the traffic-schedule and fleet-adapter
  retry loops, applied identically to `bootc-vm/scripts-overlay/` and
  `office/helm/files/` (kept byte-identical on purpose — this project has
  been burned by these two diverging before). Also added the same
  fatal-on-exhaustion pattern to the fleet-adapter loop for consistency.

With all three fixed together, a real fresh boot reached full end-to-end
success with zero manual intervention: all 4 robots discovered and
registered, all 4 patrol tasks dispatched and accepted by RMF, and
`tinyRobot1`'s odometry directly confirmed moving from its spawn point
(`x=-4.0`) to `x=7.77` toward its assigned waypoint — real task execution,
not just acceptance.

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
bootc host (Hummingbird bootc-os, x86_64, NVIDIA driver baked in)
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

**Firewalld: genuinely relevant here, not a non-issue.** `Network=host`
means these containers bind the host's real interface directly, so
Podman's usual automatic firewall punching (which only applies to bridge
networking + `PublishPort=`) doesn't help if a host firewall is active.
This section originally said firewalld wasn't installed on
`fedora-bootc:43` and was safe to ignore — no longer true now that the
host is Hummingbird's `bootc-os`, which ships firewalld enabled by default
(confirmed via `rpm -q firewalld` + `systemctl is-enabled firewalld`). See
"Host base image: Hummingbird, not fedora-bootc" above — the
`Containerfile` now actively runs `firewall-offline-cmd` to open
7447/5900/8080. Re-check this again if the base image ever changes further.

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

`config.toml` is gitignored (same pattern as this repo's `values.yaml`) —
copy the template and set your own SSH public key (no EC2 key pair needed;
neither fedora-bootc nor Hummingbird's bootc-os ship cloud-init — confirmed
directly for both — so key-pair injection wouldn't work anyway, same
reasoning `bootc-demos` bakes its own demo user):

```bash
cp bootc-vm/config.toml.example bootc-vm/config.toml
# edit bootc-vm/config.toml, replace REPLACE_WITH_YOUR_SSH_PUBLIC_KEY
```

```bash
./bootc-vm/scripts/build-ami.sh
```

This builds *and* uploads *and* registers the AMI in one step —
`bootc-image-builder`'s `--aws-*` flags do the full pipeline, no manual
`import-snapshot`/`register-image` needed.

Three gotchas hit and fixed while first running this (all now handled by the
script, documented here so they aren't rediscovered):
- **Neither `fedora-bootc` nor Hummingbird's `bootc-os` have a default root
  filesystem type** — `bib` fails with `missing required info:
  DefaultRootFs` without an explicit `--rootfs` flag. **`ext4`, not
  `xfs`** — confirmed by a real failure migrating to Hummingbird:
  `mkfs.xfs: No such file or directory` inside `bib`'s disk-assembly
  sandbox. Isolated cheaply (a local `--type qcow2` test, no AWS/S3
  involved, ~1 min to fail vs. a ~25-30 min full AMI cycle) to `xfsprogs`
  genuinely not being installed anywhere in the Hummingbird image
  (`e2fsprogs` is present) — osbuild's mkfs stage needs the filesystem
  tool present in the *source* image itself, not just `bib`'s own
  buildroot. `ext4` (`ROOTFS=ext4`, now the default) works cleanly
  end-to-end on Hummingbird; this wasn't an issue on fedora-bootc since it
  ships `xfsprogs` by default.
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
- [x] Verified the Hummingbird base (`quay.io/hummingbird-community/bootc-os`)
      hands-on before migrating: kernel NVR match, Quadlet generator
      presence, package availability all confirmed directly via disposable
      `podman run` containers (zero AWS cost)
- [x] Migrated `Containerfile` to Hummingbird; found + fixed two new
      failure modes not seen on fedora-bootc: global `$releasever`
      override (RPM Fusion's own repo files break under Hummingbird's
      date-based `VERSION_ID`) and `rpm -Uvh --nodeps --nosignature` for
      the RPM Fusion release RPMs (avoids a `system-release` conflict with
      `hummingbird-release`); restored the `firewall-offline-cmd` step
      (firewalld is enabled by default here, unlike fedora-bootc); added
      an explicit `openssl` install
- [x] Rebuilt + relaunched on Hummingbird; all 11 units, GPU/CDI, and real
      lidar data confirmed working identically to the fedora-bootc build
- [x] Found + fixed firewalld's default zone silently dropping Gazebo's own
      transport (UDP multicast discovery + ephemeral TCP data channels) —
      fixed via `--set-default-zone=trusted` (safe given `Network=host`
      everywhere; AWS Security Group is the real boundary)
- [x] Found + fixed `wait-for-service.sh` missing from the deployed app
      image tag (misdiagnosed as a cold-start "race" until traced down) —
      rebuilt + re-pushed `quay.io/rhkp/openrmf-openshift-office-demo:nav2-sensors`
- [x] Found + fixed duplicate fleet-adapter processes racing on the same
      ROS node name, caused by plain `kill` (SIGTERM) not reliably
      terminating a failed retry attempt — fixed with SIGKILL +
      confirm-dead polling in both `launch-simulation-world-only-viz.sh`
      copies
- [x] **Full end-to-end success on a cold, unmodified boot, zero manual
      intervention**: AMI `ami-030d818128f283ac8`, instance
      `i-0402307e8194e0fb2` — all 4 robots discovered, all 4 patrol tasks
      dispatched and accepted, `tinyRobot1` odometry confirmed moving
      toward its waypoint
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
