# Hummingbird base-image migration

Goal: every container this repo builds should be `FROM` a credible
[Project Hummingbird](https://hummingbird-project.io/) base image, fully
replacing both `docker.io/osrf/ros:jazzy-desktop` (Ubuntu/apt, used by
`common/Dockerfile` for all three demos) and
`quay.io/centos-bootc/centos-bootc:stream9` (the `bootc-fedora-robostack`
branch's office-only `bootc/Containerfile`) — not running Hummingbird
alongside bootc as a comparison, but disconnecting from bootc entirely once
parity is reached.

This directory is isolated from `bootc/`, `common/`, `office/helm/`, etc. —
nothing outside `hummingbird/` is modified until a given phase below is
proven and validated.

## Why Fedora appears in these Containerfiles

If you read `scripts/spike.Containerfile` (or the real `Containerfile` once
Phase 2 lands) and see a Fedora repo added alongside the Hummingbird base,
that is intentional, not a shortcut or a sign this migration is "really"
just Fedora with a Hummingbird label on it. The quantified picture:

- **`bootc-os` itself is ~95% genuine Hummingbird.** Its own lockfile
  (`images/bootc-os/hummingbird/default/rpms/rpms.lock.yaml` in
  `gitlab.com/redhat/hummingbird/containers`) has 872 package entries across
  both architectures; 828 are Hummingbird-rebuilt (`.hum1`), only 44 come
  from Fedora (niche bootloader/container-host packages like
  `fuse-overlayfs`, `os-prober`, `shim-x64` that Hummingbird hasn't rebuilt
  yet). Falling back to Fedora for a small gap is Hummingbird's own
  sanctioned pattern for `bootc-os`, not something this project invented.
- **Our own package list is similarly lopsided.** Confirmed empirically
  (see `scripts/spike.Containerfile`'s build log): the entire build
  toolchain — `curl`, `tar`, `bzip2`, `which`, `git`, `gcc`, `gcc-c++`,
  `cmake`, `make`, `patch`, `libatomic`, `boost-devel` — resolves from
  Hummingbird's own `.hum1` catalog. `cmake` and `boost-devel` only pull
  from Fedora for one missing *transitive* dependency each (`libjsoncpp`,
  `python3-numpy`) — the packages themselves are Hummingbird's.
- **Only the GL/X11 desktop-rendering stack is genuinely absent from
  Hummingbird** — `tinyxml`, `tinyxml-devel`, `mesa-libGL`, `mesa-libEGL`,
  `mesa-dri-drivers`, `xorg-x11-server-Xvfb`, `x11vnc`, `openbox`, and their
  own X11/Mesa dependency trees (`libX11`, `cairo`, `pango`, `libdrm`, etc.)
  don't exist under any version in Hummingbird's rebuilt catalog. Confirmed
  by testing `dnf install` against Hummingbird's own repo alone first: these
  came back as "No match for argument" (genuinely absent), not a dependency
  resolution failure.
- **Why this specific category is missing:** Project Hummingbird's mission
  is minimal, hardened *server/CLI* images (language runtimes, databases,
  web servers) plus one headless bootable-OS image for running containers.
  A GPU-rendering X11/Mesa desktop stack — inherently a large attack
  surface, the opposite of "minimal hardened" — has never been in scope for
  any Hummingbird image, including `bootc-os` (a headless container host,
  not a desktop). It's not that Hummingbird chose Fedora over their own
  packages for Xvfb/Mesa; no Hummingbird build of these packages exists
  anywhere to choose from.

Net effect for anyone building these images: expect the resulting image to
be overwhelmingly Hummingbird-hardened content, with a small, well-defined,
intentional Fedora carve-out limited to the GL/X11 rendering stack our demo
needs (RViz/Gazebo/noVNC) that has no Hummingbird equivalent today.

## Registry map

Confirmed by reading the actual Hummingbird source
(`gitlab.com/redhat/hummingbird/containers`, README lines 110–121), not
secondary blog posts:

| Registry prefix | Meaning |
|---|---|
| `registry.access.redhat.com/hi/` | Red Hat supported — hardened, distroless, recommended |
| `quay.io/hummingbird/` | Unsigned mirror of the same supported images — same content, no Red Hat entitlement needed |
| `quay.io/hummingbird-community/` | Community tier (MinIO, **bootc-os**) — same build infra, no support commitment |
| `quay.io/hummingbird-rawhide/` | Straight upstream Fedora Rawhide packages, same tooling |
| `quay.io/hummingbird-ci/` | Build infrastructure only (`hummingbird-builder`, `gitlab-ci`) — **not** an application base |

`quay.io/hummingbird-ci/hummingbird-builder` was the original candidate
under discussion — it's genuinely produced by the Hummingbird project, but
it's a CI tool image (assembles other images' rootfs via `dnf-installroot`,
also used for SLSA/cosign reproducibility verification), not something to
put in a `FROM` line. Its own catalog of rebuilt (`.hum1`) packages has zero
coverage of desktop/GL/X11 packages (`mesa-libGL`, `Xvfb`, `boost-devel`,
`tinyxml`, `gcc-c++` — grepped every `rpms.lock.yaml` in the repo, zero
hits), since nothing in Hummingbird's ~100-image catalog needs them.

**`quay.io/hummingbird-community/bootc-os`** is the real answer for anything
needing a full OS (GL/X11/build toolchain). Verified by reading its actual
Containerfile (`images/bootc-os/hummingbird/default/Containerfile`) and
`properties.yml` in the Hummingbird repo, not marketing copy:
- Ships `dnf5` as a real package in the final image, not a builder-only tool.
- Bootable/OS-shaped (kernel, systemd, grub2, ostree) — same shape as
  `centos-bootc`.
- `allow_fedora_repos: true` — its own lockfile already mixes `fedora-43`
  and `public-hummingbird-*` repoids by design, not restricted to the
  narrow hardened-only catalog.
- Fedora 43-based (not CentOS Stream 9) — no `epel-release` needed for
  `tinyxml-devel` etc., Fedora ships it natively.
- Its own README documents extending it exactly like `centos-bootc`:
  `FROM bootc-os` then `RUN dnf install -y htop`.
- Labeled experimental/community, not production — acceptable for a demo
  repo.

**Correction from empirical testing** (the static Containerfile/rootfs-overlay
reading below undersold what's actually shipped): `bootc-os` **does** ship a
working `/etc/yum.repos.d/hummingbird.repo` baked into the image
(`public-hummingbird-$basearch-rpms`, confirmed via
`podman run --rm quay.io/hummingbird-community/bootc-os:latest cat /etc/yum.repos.d/*.repo`)
— it must come from an RPM package pulled in by `MAIN_PACKAGES`, not the
manual `rootfs/` overlay directory this analysis originally checked. That
repo alone is not enough for our workload though: a plain `dnf install` dry
run against it showed `gcc`/`gcc-c++`/`make`/`patch`/`libatomic` resolve
fine, but `tinyxml-devel`/`mesa-libGL`/`mesa-libEGL`/`mesa-dri-drivers`/
`Xvfb`/`x11vnc`/`openbox`/`tinyxml` don't exist as package names at all, and
even `cmake`/`boost-devel` (which *do* exist there) fail on transitive deps
missing from the same repo (`cmake` needs `libjsoncpp.so.26`; `boost-devel`
needs `python3-numpy` → `boost-numpy3`). A Fedora fallback repo is genuinely
required, not optional — see `scripts/spike.Containerfile`.

Two more things the spike surfaced:
- Don't reuse Fedora's own repo file via
  `COPY --from=fedora:43 /etc/yum.repos.d/fedora.repo`: its `baseurl` is
  templated on `$releasever`, which resolves against `bootc-os`'s own
  `/etc/os-release` (`ID=hummingbird`, `VERSION=20251124`) instead of `"43"`,
  producing a 404'ing metalink URL. Write a repo file with a hardcoded
  release number instead.
- `xorg-x11-utils` (and its constituent tools `xdpyinfo`/`xwininfo`/`xrandr`)
  is genuinely gone from Fedora 43, not renamed — `dnf search` for all three
  returns "No matches found" against the full repo. It's diagnostic-only,
  not required by `Xvfb`/Gazebo/RViz/noVNC themselves, so it's dropped from
  our package list rather than substituted.

## Per-container plan

| Container | Current base | Hummingbird base |
|---|---|---|
| `common/Dockerfile` (office+airport+hotel) | `docker.io/osrf/ros:jazzy-desktop` | `quay.io/hummingbird-community/bootc-os:latest` + RoboStack/micromamba (same technique proven on `bootc/Containerfile`) |
| `common/novnc/Dockerfile` | `python:3.12-alpine` | `quay.io/hummingbird/python:3.12-builder` (real hardened tier) |
| `common/zenoh-router/Dockerfile` | `docker.io/ros:jazzy` | `quay.io/hummingbird-community/bootc-os:latest` + RoboStack, single package |
| `common/rmf-web-zenoh/Dockerfile` | `ghcr.io/open-rmf/rmf-web/api-server:jazzy-nightly` | **No viable base** — extends a third-party prebuilt image we don't control; would need forking rmf-web upstream. Documented exception, stays as-is. |

## Status

- [x] Spike: `dnf install` against `hummingbird.repo` + a self-supplied
      Fedora 43 fallback repo resolves our full desktop/GL/build-tool
      package list cleanly on `bootc-os` under plain `podman build`
      (`scripts/spike.Containerfile`, built and smoke-tested on the build
      VM — `gcc`/`g++` 16.2.1, `cmake` 4.3.0, `Xvfb` starts clean, `libGL.so.1`
      resolves all deps, `openbox`/`x11vnc`/`bash` all present)
- [ ] Port `bootc/Containerfile` → `hummingbird/Containerfile` (office scope
      only, mirrors the existing bootc scope)
- [ ] `hummingbird/office-values.yaml`, deployed side-by-side with the
      existing office demo, validated at parity
- [ ] Investigate fiona/`m-explore-ros2` gap for airport/hotel parity
- [ ] `common/novnc/Dockerfile` → `quay.io/hummingbird/python` tier
- [ ] `common/zenoh-router/Dockerfile` → `bootc-os` + RoboStack-lite
- [ ] Retire `bootc/` and `common/Dockerfile` once everything above is
      validated

## Building the spike

Run on the build VM (podman, not locally — see project memory on podman
stability):

```bash
podman build -f hummingbird/scripts/spike.Containerfile -t spike-hummingbird-bootc-os .
```

Smoke-test the result:

```bash
podman run --rm spike-hummingbird-bootc-os gcc --version
podman run --rm spike-hummingbird-bootc-os cmake --version
podman run --rm spike-hummingbird-bootc-os bash -c "Xvfb :99 -screen 0 1024x768x24 & sleep 2 && ldd /usr/lib64/libGL.so.1"
podman run --rm spike-hummingbird-bootc-os sh -c "which openbox x11vnc bash"
```
