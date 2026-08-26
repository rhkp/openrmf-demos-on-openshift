# Spike: prove quay.io/hummingbird-community/bootc-os can serve as a
# drop-in replacement for quay.io/centos-bootc/centos-bootc:stream9 for our
# RoboStack/RMF workload — same usage pattern (FROM + dnf install), just a
# different base. See ../README.md for the full analysis.
#
# Two things this spike de-risks before writing the real hummingbird/Containerfile:
#   1. bootc-os ships its own hummingbird.repo (public-hummingbird catalog)
#      baked in, but that catalog alone can't resolve our full desktop/GL/
#      build-tool package list (confirmed empirically below) — need a
#      correctly-configured Fedora fallback repo alongside it.
#   2. bootc-os is labeled experimental/community — confirm it behaves
#      sanely under plain `podman build` (no Konflux/Tekton scaffolding).
#
# Build on the build VM (podman, not locally — see project memory on podman
# stability): podman build -f hummingbird/scripts/spike.Containerfile -t spike-hummingbird-bootc-os .

FROM quay.io/hummingbird-community/bootc-os:latest

# bootc-os ships /etc/yum.repos.d/hummingbird.repo baked in (contrary to
# this script's earlier assumption, confirmed by direct inspection:
# `podman run --rm quay.io/hummingbird-community/bootc-os:latest cat
# /etc/yum.repos.d/*.repo`). That repo alone resolves gcc/gcc-c++/make/
# patch/libatomic fine, but leaves real gaps confirmed by a plain `dnf
# install` dry run against it: tinyxml-devel/mesa-*/Xvfb/x11vnc/openbox
# don't exist as package names at all, and even packages that DO exist
# there (cmake, boost-devel) fail on transitive deps missing from the same
# repo (cmake needs libjsoncpp.so.26; boost-devel needs
# python3-numpy -> boost-numpy3). A Fedora fallback repo is genuinely
# required, not optional.
#
# Don't reuse Fedora's own repo file via COPY --from=fedora:43 — its
# baseurl is templated on $releasever, which resolves against bootc-os's
# own /etc/os-release (ID=hummingbird, VERSION=20251124) instead of "43",
# producing a broken metalink URL (confirmed by trying it first). Hardcode
# the release number instead.
RUN printf '%s\n' \
      '[fedora-43]' \
      'name=Fedora 43 - $basearch' \
      'baseurl=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/$basearch/os/' \
      'enabled=1' \
      'gpgcheck=0' \
      'skip_if_unavailable=True' \
      > /etc/yum.repos.d/fedora-43.repo

# curl/tar/which/git are already part of bootc-os's own MAIN_PACKAGES —
# listed anyway so this package set is self-documenting; dnf just no-ops
# on the ones already present.
# xorg-x11-utils (xdpyinfo/xwininfo/xrandr) is genuinely gone from Fedora
# 43 — not renamed, dropped upstream (confirmed: `dnf search` for its
# constituent tools returns "No matches found" against the full Fedora 43
# repo). It's diagnostic-only, not required by Xvfb/Gazebo/RViz/noVNC
# themselves, so it's dropped here rather than substituted.
RUN dnf -y install \
      curl tar bzip2 which git \
      gcc gcc-c++ cmake make patch libatomic boost-devel tinyxml-devel \
      mesa-libGL mesa-libEGL mesa-dri-drivers \
      xorg-x11-server-Xvfb x11vnc openbox \
      tinyxml boost \
    && dnf clean all

CMD ["tail", "-f", "/dev/null"]
