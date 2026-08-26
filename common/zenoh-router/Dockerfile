# Zenoh router for OpenRMF — uses the rmw_zenoh bundled router (rmw_zenohd)
# to guarantee protocol version compatibility with rmw_zenoh_cpp clients.
# Hummingbird-based: quay.io/hummingbird-community/bootc-os is the only
# bootable/OS-shaped Hummingbird image; ROS2 has no Hummingbird package at
# all (out of that project's scope), so RoboStack/conda supplies just the
# one package needed here. See ../../hummingbird/README.md.
FROM quay.io/hummingbird-community/bootc-os:latest

# bootc-os ships its own hummingbird.repo, but not the full desktop/build
# package set — this image only needs curl/tar/bzip2 from a fallback repo,
# same fallback used by the main hummingbird/Containerfile build.
RUN printf '%s\n' \
      '[fedora-43]' \
      'name=Fedora 43 - $basearch' \
      'baseurl=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/$basearch/os/' \
      'enabled=1' \
      'gpgcheck=0' \
      'skip_if_unavailable=True' \
      > /etc/yum.repos.d/fedora-43.repo

RUN dnf -y install curl tar bzip2 which && dnf clean all

ENV MAMBA_ROOT_PREFIX=/opt/micromamba
ENV PATH=${MAMBA_ROOT_PREFIX}/envs/zenoh_env/bin:${PATH}
ENV ROS_ENV_SETUP=${MAMBA_ROOT_PREFIX}/envs/zenoh_env/setup.bash

# bootc-os's minimal filesystem package doesn't pre-create /usr/local/bin
# (unlike a traditional full-FHS image such as centos-bootc) — create it first.
RUN mkdir -p /usr/local/bin && \
    curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj -C /usr/local/bin/ --strip-components=1 bin/micromamba

# ros-jazzy-rmw-zenoh-cpp alone only provides the RMW implementation
# library, not the `ros2` CLI itself — the original apt-based image got
# `ros2` for free from the docker.io/ros:jazzy base (ros-core). RoboStack's
# equivalent is ros-jazzy-ros-base (provides ros2cli + rclcpp/rclpy, same
# split as the upstream ros-base apt metapackage).
RUN micromamba create -y -n zenoh_env -c robostack-jazzy -c conda-forge \
      ros-jazzy-ros-base ros-jazzy-rmw-zenoh-cpp && \
    micromamba clean -a -y

COPY router-config.json5 /etc/zenoh/router-config.json5

RUN mkdir -p /var/zenoh && \
    chgrp -R 0 /var/zenoh /etc/zenoh && \
    chmod -R g+rwX /var/zenoh /etc/zenoh

USER 1001
WORKDIR /var/zenoh

EXPOSE 7447

ENTRYPOINT ["/bin/bash", "-c"]
CMD ["source ${ROS_ENV_SETUP} && exec ros2 run rmw_zenoh_cpp rmw_zenohd -- --config /etc/zenoh/router-config.json5"]
